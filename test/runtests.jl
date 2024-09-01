using NMRInversions
using LinearAlgebra
using Test
using Optimization, OptimizationOptimJL


function test1D(seq::Type{<:pulse_sequence1D})

    x = exp10.(range(log10(1e-4), log10(5), 32)) # acquisition range

    X = exp10.(range(-5, 1, 128)) # T range

    K = create_kernel(seq, x, X)
    f_custom = [0.5exp.(-(x)^2 / 3) + exp.(-(x - 1.3)^2 / 0.5) for x in range(-5, 5, length(X))]

    g = K * f_custom
    y = g + 0.001 * maximum(g) .* randn(length(x))

    results = invert(seq, x, y, alpha=gcv)

    return norm(results.f - f_custom) < 0.5
end


function test_lcurve()
    # @time begin

    # x = exp10.(range(log10(1e-4), log10(5), 32)) # acquisition range
    x = collect(range(0.01, 2, 32))
    X = exp10.(range(-5, 1, 128)) # T range
    # K = create_kernel(IR, x, X)
    K = create_kernel(CPMG, x, X)
    f_custom = [0.5exp.(-(x)^2 / 3) + exp.(-(x - 1.3)^2 / 0.5) for x in range(-5, 5, length(X))]

    g = K * f_custom
    noise_level = 0.001 * maximum(g)
    y = g + noise_level .* randn(length(x))

    alphas = exp10.(range(log10(1e-5), log10(1), 128))
    curvatures = zeros(length(alphas))
    xis = zeros(length(alphas))
    rhos = zeros(length(alphas))
    order = 0

    U, s, V = svd(K)
    s_keep_ind = findall(x -> x > noise_level, s)
    U = U[:, s_keep_ind]
    s = s[s_keep_ind]
    V = V[:, s_keep_ind]
    K = U * Diagonal(s) * V'

    for (i, α) in enumerate(alphas)
        A = sparse([K; √(α) .* NMRInversions.Γ(size(K, 2), order)])
        println(α)

        # f = vec(nonneg_lsq(A, [y; zeros(size(A, 1) - size(y, 1))], alg=:nnls))
        # r = K * f - y
        f, r = NMRInversions.solve_regularization(K, y, α, brd, 0)

        ξ = f'f
        ρ = r'r
        λ = √α

        # z = vec(nonneg_lsq(A, [r; zeros(size(A, 1) - size(r, 1))], alg=:nnls))
        f, _ = NMRInversions.solve_regularization(K, r, α, brd, 0)

        fᵢ = s .^ 2 ./ (s .^ 2 .+ α)
        βᵢ = U' * y
        ∂ξ∂λ = -(4 / λ) * sum((1 .- fᵢ) .* fᵢ .^ 2 .* (βᵢ .^ 2 ./ s .^ 2))
        # ∂ξ∂λ = (4 / λ) * f'z

        ĉ = 2 * (ξ * ρ / ∂ξ∂λ) * (α * ∂ξ∂λ * ρ + 2 * ξ * λ * ρ + λ^4 * ξ * ∂ξ∂λ) / ((α * ξ^2 + ρ^2)^(3 / 2))

        xis[i] = ξ
        rhos[i] = ρ
        curvatures[i] = ĉ

    end

    non_inf_indx = findall(!isinf, curvatures)

    α = alphas[non_inf_indx][argmax(curvatures[non_inf_indx])]

    A = sparse([K; √(α) .* NMRInversions.Γ(size(K, 2), order)])
    f, r = NMRInversions.solve_regularization(K, y, α, brd, 0)
    # f = vec(nonneg_lsq(A, [y; zeros(size(A, 1) - size(y, 1))], alg=:nnls))

    p1 = plot(alphas, curvatures, xscale=:log10)
    p1 = vline!(p1, [α], label="α = $α")
    p2 = plot(X, [f_custom, f], label=["original" "solution"], xscale=:log10)
    p3 = scatter(rhos, xis, xscale=:log10, yscale=:log10)
    p3 = scatter!([rhos[argmax(curvatures[non_inf_indx])]], [xis[argmax(curvatures[non_inf_indx])]], label="α = $α")
    p4 = scatter(x, y, label="data")
    p4 = plot!(x, K * f, label="solution")
    plot(p1, p2, p3, p4)

end


function testT1T2()

    x_direct = exp10.(range(log10(1e-4), log10(5), 1024)) # acquisition range
    x_indirect = exp10.(range(log10(1e-4), log10(5), 32)) # acquisition range

    X_direct = exp10.(range(-5, 1, 64)) # T range
    X_indirect = exp10.(range(-5, 1, 64)) # T range

    θ = 135
    σ₁ = 1.3
    σ₂ = 0.4
    x₀ = 0
    y₀ = 1.3
    a = ((cosd(θ)^2) / (2 * σ₁^2)) + ((sind(θ)^2) / (2 * σ₂^2))
    b = -((sind(2 * θ)) / (4 * σ₁^2)) + ((sind(2 * θ)) / (4 * σ₂^2))
    c = ((sind(θ)^2) / (2 * σ₁^2)) + ((cosd(θ)^2) / (2 * σ₂^2))
    F_original = ([exp.(-(a * (x - x₀)^2 + 2 * b * (x - x₀) * (y - y₀) + c * (y - y₀)^2)) for x in range(-5, 5, length(X_direct)), y in range(-5, 5, length(X_indirect))])

    K1 = create_kernel(CPMG, x_direct, X_direct)
    K2 = create_kernel(IR, x_indirect, X_indirect)

    data = K1 * F_original * K2'
    data = complex.(data, 0.001 .* maximum(real(data)) .* randn(size(data)))

    results = invert(IRCPMG, x_direct, x_indirect, data, α=0.01, rdir=(-5, 1, 64), rindir=(-5, 1, 64), savedata=false)

    # K = create_kernel(IRCPMG, x_direct, x_indirect,X_direct, X_indirect,data)
    # A = SparseArrays.sparse([K.K; √(1) .* NMRInversions.Γ(size(K.K, 2), 0)])
    # b = vec([K.g;zeros(size(A, 1) - size(K.g, 1))])
    # f = vec(nonneg_lsq(A, b, alg=:nnls))

    return LinearAlgebra.norm(results.F - F_original) < 0.5

end

function test_phase_correction(plots=false)

    # Create real and imaginary parts
    Re_original = exp.(-range(1, 20, 1000)) + randn(1000) .* 0.01
    Im_original = randn(1000) .* 0.01

    # Get them out of phase
    ϕd = rand() * 2π
    Re_shifted, Im_shifted = NMRInversions.phase_shift(Re_original, Im_original, ϕd)

    # Correct the phase
    Rₙ, Iₙ, ϕc = NMRInversions.autophase(Re_shifted, Im_shifted, 1)

    ## Plots for sanity check (using Plots.jl)
    if plots == true
        p1 = plot([Re_original, Im_original], label=["Original real" "Original Imaginary"])
        p2 = plot([Re_shifted, Im_shifted], label=["Dephased real" "Dephased Imaginary"])
        p3 = plot([Rₙ, Iₙ], label=["Corrected real" "Corrected Imaginary"])
        ϕ_range = range(0, 2π, 20000)
        Re1_vs_φ = Re_shifted[1] .* cos.(ϕ_range) - Im_shifted[1] .* sin.(ϕ_range)
        Im_sum_vs_φ = [im_cost([ϕ], (Re_shifted, Im_shifted)) for ϕ in ϕ_range]
        p4 = plot(ϕ_range, Re1_vs_φ, xlabel="ϕ", label="Re[1]")
        p4 = plot!(ϕ_range, (Im_sum_vs_φ ./ maximum(Im_sum_vs_φ)) .* maximum(Re1_vs_φ), xlabel="ϕ", label="sum(im.^2)", legend=:topleft)
        p4 = vline!(p4, [ϕc], label="corrected phase")
        display(plot(p1, p2, p3, p4))
    end

    display("The correction error is $(2π - (ϕd + ϕc)) radians")

    return abs(2π - (ϕd + ϕc)) < 0.01
end



@testset "NMRInversions.jl" begin
    # Write your tests here.
    @test test1D(IR)
    @test testT1T2()
    @test test_phase_correction()

end


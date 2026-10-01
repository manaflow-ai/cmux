import AppKit
import CmuxNextDesign

/// The window's content view: shows the current step's chosen variant on
/// that variant's surface, and swaps it on each step change with the
/// variant's transition.
final class OnboardingHostView: NSView {
    private let model: OnboardingModel
    /// Overrides the stored pick (the gallery's full-size preview).
    private let forcedVariant: (any OnboardingScreenVariant.Type)?
    private var shownStep: OnboardingModel.Step?
    private var current: NSView?
    private var lastIndex = 0
    private var loop: RenderLoop?

    init(model: OnboardingModel, variant: (any OnboardingScreenVariant.Type)? = nil) {
        self.model = model
        forcedVariant = variant
        super.init(frame: NSRect(origin: .zero, size: OnboardingMetrics.windowSize))
        autoresizingMask = [.width, .height]
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The variant showing now.
    private(set) var variant: (any OnboardingScreenVariant.Type)?

    private func render() {
        let step = model.step
        guard step != shownStep else { return }
        shownStep = step
        let chosen = forcedVariant.flatMap { $0.step == step ? $0 : nil }
            ?? OnboardingVariantRegistry.chosen(for: step, id: model.services.variantID(for: step))
        variant = chosen
        let surface = OnboardingSurfaceView(surface: chosen.surface, content: chosen.makeContent(OnboardingStepContext(model: model)))
        surface.frame = bounds
        current?.removeFromSuperview()
        addSubview(surface)
        current = surface
        let forward = model.index >= lastIndex
        lastIndex = model.index
        StepTransition.reveal(surface, transition: chosen.transition, forward: forward)
    }
}

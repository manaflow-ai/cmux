public import AppKit

/// Owns the one onboarding window: opens it at a step, brings an open one
/// to a step, and rebuilds it when it does not have the step. The App
/// supplies the model (its services) and is told when a window closed.
@MainActor
public final class OnboardingWindowPresenter {
    public typealias MakeModel = @MainActor (_ start: OnboardingModel.Step?, _ resume: OnboardingModel.Step?) -> OnboardingModel?

    /// The open onboarding window, if any.
    public private(set) var controller: OnboardingWindowController?
    /// Called after each onboarding window closed (also a rebuilt one).
    public var onWindowClose: (() -> Void)?
    /// Builds a window's model (the App's services); nil opens nothing.
    public var makeModel: MakeModel?
    private let presentWindow: @MainActor (OnboardingWindowController) -> Void

    /// `present` shows a window (tests pass one that does not put it on screen).
    public init(makeModel: MakeModel? = nil, present: @escaping @MainActor (OnboardingWindowController) -> Void = { $0.present() }) {
        self.makeModel = makeModel
        presentWindow = present
    }

    /// Whether an open window can show `step`: it already has that step (or
    /// no step was asked for). Otherwise the window is rebuilt for the step.
    public static func reusesWindow(showing steps: [OnboardingModel.Step], for step: OnboardingModel.Step?) -> Bool {
        guard let step else { return true }
        return steps.contains(step)
    }

    /// The first run (Continue Setup, a launch), at `resume` or its start.
    /// An open first run is brought forward as it is: same window, same
    /// step, nothing typed in it lost.
    public func showFirstRun(resumingAt resume: OnboardingModel.Step?) {
        if let controller, controller.model.isFirstRun { return presentWindow(controller) }
        open(step: nil, resume: resume)
    }

    /// Opens onboarding at `step`, or brings the open window to that step
    /// when it has it.
    public func show(step: OnboardingModel.Step? = nil) {
        if let controller, Self.reusesWindow(showing: controller.model.steps, for: step) {
            if let step { controller.model.go(to: step) }
            return presentWindow(controller)
        }
        open(step: step, resume: nil)
    }

    /// The first run a window replaced; it comes back when the window that
    /// holds it (`controller`) closes.
    private var interruptedFirstRun: OnboardingModel.Step?

    /// Replaces the open window (if any) with a new one. The old window is
    /// let go before it closes, so its close never touches the new one.
    private func open(step: OnboardingModel.Step?, resume: OnboardingModel.Step?) {
        var interrupted = interruptedFirstRun
        if let old = controller {
            // Closing leaves the first run unfinished (never skipped); it
            // continues at its step when the replacing window closes.
            if old.model.isFirstRun { interrupted = old.model.step }
            controller = nil
            old.closeForRebuild()
        }
        guard let model = makeModel?(step, resume) else { return }
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self, weak controller] in self?.windowDidClose(controller) }
        interruptedFirstRun = model.isFirstRun ? nil : interrupted
        self.controller = controller
        presentWindow(controller)
    }

    private func windowDidClose(_ closed: OnboardingWindowController?) {
        onWindowClose?()
        // A replaced window: the presenter already let it go.
        guard let closed, closed === controller else { return }
        controller = nil
        let resume = interruptedFirstRun
        interruptedFirstRun = nil
        // A first run this window interrupted continues where it was.
        if let resume { open(step: nil, resume: resume) }
    }
}

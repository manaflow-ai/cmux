public import AppKit

/// Owns the one onboarding window: opens it at a step, brings an open one
/// to a step, and rebuilds it when it does not have the step. The App
/// supplies the model (its services) and is told when a window closed.
@MainActor
public final class OnboardingWindowPresenter {
    public typealias MakeModel = @MainActor (_ start: OnboardingModel.Step?, _ resume: OnboardingModel.Step?) -> OnboardingModel

    /// The open onboarding window, if any.
    public private(set) var controller: OnboardingWindowController?
    /// Called after each onboarding window closed (also a rebuilt one).
    public var onWindowClose: (() -> Void)?
    private let makeModel: MakeModel
    private let presentWindow: @MainActor (OnboardingWindowController) -> Void

    /// `present` shows a window (tests pass one that does not put it on screen).
    public init(makeModel: @escaping MakeModel, present: @escaping @MainActor (OnboardingWindowController) -> Void = { $0.present() }) {
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
    public func showFirstRun(resumingAt resume: OnboardingModel.Step?) {
        show(resumingFirstRunAt: resume)
    }

    /// Opens onboarding at `step` (or brings the open one to that step).
    public func show(step: OnboardingModel.Step? = nil, resumingFirstRunAt resume: OnboardingModel.Step? = nil) {
        var interrupted: OnboardingModel.Step?
        if let controller {
            if resume == nil, Self.reusesWindow(showing: controller.model.steps, for: step) {
                if let step { controller.model.go(to: step) }
                presentWindow(controller)
                return
            }
            // The open window was built without this step (for example the
            // first run, or a helper that came up since): rebuild it. Closing
            // leaves the first run unfinished (never skipped); it continues
            // at its step when this window closes.
            if controller.model.isFirstRun { interrupted = controller.model.step }
            controller.closeForRebuild()
            self.controller = nil
        }
        let model = makeModel(step, resume)
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self] in
            self?.controller = nil
            self?.onWindowClose?()
            // A first run this window interrupted continues where it was.
            if let interrupted, !model.isFirstRun, let self {
                self.show(resumingFirstRunAt: interrupted)
            }
        }
        self.controller = controller
        presentWindow(controller)
    }
}

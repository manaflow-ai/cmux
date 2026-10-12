public import AppKit

/// Owns the one tool window (Import from Browser or Computer Use setup):
/// opens it for a tool, brings an open one forward when it shows that
/// tool, and replaces it when it shows the other. The App supplies the
/// model (its services) and is told when a window closed.
@MainActor
public final class OnboardingWindowPresenter {
    public typealias MakeModel = @MainActor (_ step: OnboardingModel.Step) -> OnboardingModel?

    /// The open tool window, if any.
    public private(set) var controller: OnboardingWindowController?
    /// Called after each tool window closed (also a replaced one).
    public var onWindowClose: (() -> Void)?
    /// Builds a window's model (the App's services); nil opens nothing.
    public var makeModel: MakeModel?
    private let presentWindow: @MainActor (OnboardingWindowController) -> Void

    /// `present` shows a window (tests pass one that does not put it on screen).
    public init(makeModel: MakeModel? = nil, present: @escaping @MainActor (OnboardingWindowController) -> Void = { $0.present() }) {
        self.makeModel = makeModel
        presentWindow = present
    }

    /// Opens the window for `step`, or brings the open one forward when it
    /// shows `step`. `prepare` sets up the window's model before it shows
    /// (`reused`: the open window's).
    public func show(step: OnboardingModel.Step, prepare: ((_ model: OnboardingModel, _ reused: Bool) -> Void)? = nil) {
        if let controller, controller.model.step == step {
            prepare?(controller.model, true)
            return presentWindow(controller)
        }
        if let old = controller {
            // Let go before it closes, so its close never touches the new window.
            controller = nil
            old.close()
        }
        guard let model = makeModel?(step) else { return }
        prepare?(model, false)
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self, weak controller] in self?.windowDidClose(controller) }
        self.controller = controller
        presentWindow(controller)
    }

    private func windowDidClose(_ closed: OnboardingWindowController?) {
        onWindowClose?()
        // A replaced window: the presenter already let it go.
        guard let closed, closed === controller else { return }
        controller = nil
    }
}

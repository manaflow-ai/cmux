public import AppKit
public import CmuxNextDesign

/// Owns the one tool window (the first-run Agents and Computer Use pages, Import from Browser or
/// Computer Use setup):
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
    /// The app's ``ActiveLookScope``, for each tool window's backdrop.
    private let activeLook: ActiveLookScope?
    /// First-run pages waiting for the tool window that shows now to close, in order.
    public private(set) var pendingFirstRun: [OnboardingModel.Step] = []

    /// `present` shows a window (tests pass one that does not put it on screen).
    public init(makeModel: MakeModel? = nil, activeLook: ActiveLookScope?,
                present: @escaping @MainActor (OnboardingWindowController) -> Void = { $0.present() }) {
        self.makeModel = makeModel
        self.activeLook = activeLook
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
        let controller = OnboardingWindowController(model: model, activeLook: activeLook)
        controller.onClose = { [weak self, weak controller] in self?.windowDidClose(controller) }
        self.controller = controller
        presentWindow(controller)
    }

    /// First run only, once per app channel (`defaults`): the Agents step, when `source` lists an
    /// installed agent CLI and no tool window shows. None found, nothing opens; an existing
    /// installation (`isFirstRun` false) never gets it.
    /// `computerUse`: the Computer Use page follows (``showComputerUseAtFirstRun``); false when a managed
    /// policy turns Computer Use off.
    public func showAgentsAtFirstRun(isFirstRun: Bool, source: (any AgentSignInSource)?, computerUse: Bool = false,
                                     defaults: UserDefaults = .standard) async {
        await agentsAtFirstRun(isFirstRun: isFirstRun, source: source, defaults: defaults)
        if computerUse { showComputerUseAtFirstRun(isFirstRun: isFirstRun, available: true, defaults: defaults) }
    }

    private func agentsAtFirstRun(isFirstRun: Bool, source: (any AgentSignInSource)?, defaults: UserDefaults) async {
        let key = "home.firstRun.agentsShown"
        guard !defaults.bool(forKey: key) else { return }
        // An upgrade is no first run; a first run marks it only once the step showed.
        guard isFirstRun else { return defaults.set(true, forKey: key) }
        guard let source, !(await source.agentSignIns(recheck: false)).isEmpty, controller == nil else { return }
        show(step: .agents)
        defaults.set(true, forKey: key)
    }

    /// First run only, once per app channel (`defaults`): the Computer Use page (Agents Can Use
    /// Your Apps). It opens after the tool window that shows now (the Agents step) closes, or at
    /// once when none shows. `available` false (Computer Use turned off by a managed policy, or
    /// no Computer Use in this build) opens nothing; an existing installation never gets it.
    public func showComputerUseAtFirstRun(isFirstRun: Bool, available: Bool, defaults: UserDefaults = .standard) {
        let key = "home.firstRun.computerUseShown"
        guard !defaults.bool(forKey: key) else { return }
        guard isFirstRun else { return defaults.set(true, forKey: key) }
        guard available else { return }
        defaults.set(true, forKey: key)
        if controller == nil { show(step: .computerUseWelcome) } else { pendingFirstRun.append(.computerUseWelcome) }
    }

    private func windowDidClose(_ closed: OnboardingWindowController?) {
        onWindowClose?()
        // A replaced window: the presenter already let it go.
        guard let closed, closed === controller else { return }
        controller = nil
        // Allow Access on the first-run page opens the setup for the grants; else the next
        // first-run page, if one waits.
        if let next = closed.model.followUp {
            show(step: next)
        } else if !pendingFirstRun.isEmpty {
            show(step: pendingFirstRun.removeFirst())
        }
    }
}

public import CmuxNextAgentIntegrations
public import AppKit
public import CmuxNextDesign

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
    /// ``untilClosed()`` callers, resumed once no tool window shows.
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The app's ``ActiveLookScope``, for each tool window's backdrop.
    private let activeLook: ActiveLookScope?

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
    public func showAgentsAtFirstRun(isFirstRun: Bool, source: (any AgentSignInSource)?, defaults: UserDefaults = .standard) async {
        let key = Self.agentsShownKey
        guard !defaults.bool(forKey: key) else { return }
        // An upgrade is no first run; a first run marks it only once the step showed.
        guard isFirstRun else { return defaults.set(true, forKey: key) }
        // Installed agents only: the step's Install for a missing one is drawn by the onboarding page, not
        // AgentsStepView, so a Mac with none would get an empty step until that page shows it.
        guard let source, (await source.agentSignIns(recheck: false)).contains(where: \.installed), controller == nil else { return }
        show(step: .agents)
        defaults.set(true, forKey: key)
    }

    /// Returns once no tool window shows: at once when none is open, else after the open one
    /// closed (Continue, Skip or its close button). A replacing window is waited out too, so the
    /// next first-run step never shows beside a tool window.
    public func untilClosed() async {
        guard controller != nil else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    /// The Agents step's once flag; the Set Up cmux card (``FirstRunSetup``) sets it in its place.
    public static let agentsShownKey = "home.firstRun.agentsShown"

    /// Bring your history's once flag (the App shows that page); unset, and no Set Up cmux card started, this Mac
    /// never finished a first launch.
    public static let historyShownKey = "home.firstRun.historyImportShown"

    /// Whether this launch is the Mac's first, read before the first-run steps set their flags:
    /// the hang-report card waits for the next launch.
    public static func isFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: historyShownKey) && defaults.string(forKey: FirstRunSetup.stateKey) == nil
    }

    /// The first-run steps, one at a time: Agents first (it gets a person to a working agent), then
    /// cmux Tools (``showAgentToolsAtFirstRun(isFirstRun:source:)``), then `next` (Bring your
    /// history) once no tool window shows. Each keeps its own once flag.
    public func showFirstRunSteps(isFirstRun: Bool, source: (any AgentSignInSource)?, agentTools: (any AgentToolsSource)? = nil,
                                  defaults: UserDefaults = .standard, then next: @MainActor () -> Void) async {
        await showAgentsAtFirstRun(isFirstRun: isFirstRun, source: source, defaults: defaults)
        await untilClosed()
        await showAgentToolsAtFirstRun(isFirstRun: isFirstRun, source: agentTools)
        await untilClosed()
        next()
    }

    /// First run only: the cmux Tools step, asking whether cmux may add its MCP server to the
    /// person's coding agents, when nobody answered yet (`agents.cmuxMcp` is `ask`), a coding agent
    /// is installed to add it to, and no tool window shows. The answer is its once flag: an existing
    /// installation, or a Mac with no agent, is never asked here (Settings > Agents keeps the row).
    public func showAgentToolsAtFirstRun(isFirstRun: Bool, source: (any AgentToolsSource)?) async {
        guard isFirstRun, let source, source.agentToolsChoice() == .ask, controller == nil else { return }
        guard !(await source.agentToolsAgents()).isEmpty, controller == nil else { return }
        show(step: .agentTools)
    }

    private func windowDidClose(_ closed: OnboardingWindowController?) {
        onWindowClose?()
        // A replaced window: the presenter already let it go.
        guard let closed, closed === controller else { return }
        controller = nil
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }
}

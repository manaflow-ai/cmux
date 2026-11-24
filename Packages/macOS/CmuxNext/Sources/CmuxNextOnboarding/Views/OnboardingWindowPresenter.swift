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

    /// Set once this Mac finished its first launch: the first-run windows ran, or the Set Up cmux card ended. Unset,
    /// and no Set Up cmux card started, this Mac never finished a first launch. The key keeps the name it had when
    /// that last step was Bring your history (removed), so a Mac that finished one before is not asked again.
    public static let historyShownKey = "home.firstRun.historyImportShown"

    /// Whether this launch is the Mac's first, read before the first-run steps set their flags:
    /// the hang-report card waits for the next launch.
    public static func isFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: historyShownKey) && defaults.string(forKey: FirstRunSetup.stateKey) == nil
    }

    /// The first-run steps: Agents (it gets a person to a working agent), then `next` (the first launch
    /// is finished) once no tool window shows. The step keeps its own once flag.
    public func showFirstRunSteps(isFirstRun: Bool, source: (any AgentSignInSource)?,
                                  defaults: UserDefaults = .standard, then next: @MainActor () -> Void) async {
        await showAgentsAtFirstRun(isFirstRun: isFirstRun, source: source, defaults: defaults)
        await untilClosed()
        next()
    }

    /// What a launch shows before the person's own work, read from the launch's environment and arguments.
    public enum LaunchSteps: Sendable, Equatable {
        /// Capture builds, the showcase, `CMUX_NEXT_SKIP_ONBOARDING=1` or `--skip-onboarding`: nothing.
        case none
        /// The default: the long first-run onboarding stays off (Lawrence 2026-11-09: no Agents window, card or
        /// history page); a new person gets only the one short Make cmux Yours screen (cmux#48416) and then their
        /// first chat. cmux's tools come with the app (`agents.cmuxMcp` defaults to `on`), so nothing asks.
        case standard
        /// `CMUX_NEXT_ONBOARDING=1` or `--onboarding`: the first-run steps.
        case firstRun

        /// `showcase` is the DEBUG showcase profile, which never shows onboarding.
        public init(environment: [String: String], arguments: [String], showcase: Bool = false) {
            if showcase || environment["CMUX_NEXT_SKIP_ONBOARDING"] == "1" || arguments.contains("--skip-onboarding") {
                self = .none
            } else if environment["CMUX_NEXT_ONBOARDING"] == "1" || arguments.contains("--onboarding") {
                self = .firstRun
            } else {
                self = .standard
            }
        }

        /// No first-run windows, card or history page this launch.
        public var skipsFirstRun: Bool { self != .firstRun }
    }

    /// The launch's steps before the person's own work: none; on a first run Make cmux Yours
    /// (``showMakeItYoursAtFirstRun(isFirstRun:defaults:)``); or, with onboarding on, the first run,
    /// for which this returns true.
    public func showLaunchSteps(_ steps: LaunchSteps, isFirstRun: Bool = false, defaults: UserDefaults = .standard) async -> Bool {
        switch steps {
        case .none: return false
        case .standard:
            await showMakeItYoursAtFirstRun(isFirstRun: isFirstRun, defaults: defaults)
            await untilClosed()
            return false
        case .firstRun:
            await showMakeItYoursAtFirstRun(isFirstRun: isFirstRun, defaults: defaults)
            await untilClosed()
            return true
        }
    }

    /// Set once a first run opened its new agent chat, or a launch was no first run (cmux#48416).
    public static let firstChatOpenedKey = "home.firstRun.firstChatOpened"

    /// Whether this launch opens the first-run agent chat, marking it decided when so: a first run, not a capture
    /// build or the showcase (`.none`), not a person who picked terminal-first. An upgrade marks it and gets none.
    public static func claimFirstChat(isFirstRun: Bool, steps: LaunchSteps, terminalFirst: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard steps != .none, !defaults.bool(forKey: firstChatOpenedKey) else { return false }
        defaults.set(true, forKey: firstChatOpenedKey)
        return isFirstRun && !terminalFirst
    }

    /// Make cmux Yours' once flag.
    public static let makeItYoursShownKey = "home.firstRun.makeItYoursShown"

    /// A new person's one setup screen (cmux#48416): how they work (GUI-first, recommended, or
    /// terminal-first), the density and a background, once per app channel (`defaults`) and only on a
    /// first run: an existing installation (`isFirstRun` false) keeps its settings and never sees it.
    public func showMakeItYoursAtFirstRun(isFirstRun: Bool, defaults: UserDefaults = .standard) async {
        let key = Self.makeItYoursShownKey
        guard !defaults.bool(forKey: key) else { return }
        // An upgrade is no first run; a first run marks it only once the step showed.
        guard isFirstRun else { return defaults.set(true, forKey: key) }
        guard controller == nil else { return }
        show(step: .makeItYours)
        defaults.set(true, forKey: key)
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

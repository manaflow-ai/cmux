public import CmuxNextDaemon

/// The answer to "Some sessions did not end" (`QuitFailureAlert`).
public enum QuitFailureAnswer: Equatable, Sendable {
    case retry
    case quitAnyway
}

/// The work between the quit decision and AppKit's reply, in order:
/// save and close windows
/// (incognito workspaces close here), then, for an End choice, end the
/// local acpmux agents (except the Home Chief's), then the local terminals,
/// and stop the local daemon (End Everything deletes the local workspaces
/// but Home first). Agents end first: their tool shells must not see the
/// terminals vanish under a turn that still runs. A step of the end that fails is shown
/// with Retry and Quit Anyway (`confirmFailures`); the quit never goes on
/// silently past one. Keep never touches the daemon. A save step past its
/// limit keeps running. An End quit waits for it before its sessions end, at
/// most ``endQuitSaveWait``; its deadline is armed only as the engines stop,
/// so a save still late then runs on beside the engine stop. A keep quit
/// waits for it before the browser engines stop, for what its deadline
/// leaves less ``QuitDeadline/engineCloseWait`` and the reply margin. The
/// browser engines stop last: Chromium's own Mac shutdown watchdog ends the
/// process with exit code 2 when CefShutdown runs past 10 s (a loaded
/// machine), so nothing the user asked for may come after it. Before
/// AppKit's reply the quit waits for every step still running (Cloud's
/// credential cleanup, a save the engine reserve cut short), for what is
/// left of the deadline less the reply margin.
public struct QuitSteps {
    public var prepareWindows: @MainActor () async -> Void
    /// Ends the local sessions as the quit's choice says; returns every step that failed.
    public var endLocalSessions: @MainActor () async -> [EndSessionsFailure]
    /// Shows the failures and waits for Retry or Quit Anyway.
    public var confirmFailures: @MainActor ([EndSessionsFailure]) async -> QuitFailureAnswer
    /// Ends the local acpmux agents (`_acpmux/shutdown endAgents`), before
    /// the terminals; returns its failure, if any.
    public var endLocalAgents: @MainActor () async -> [EndSessionsFailure]
    public var stopBrowserEngines: @MainActor () async -> Void
    /// Restart to Update: hands acpmux to the new build (`AcpmuxUpdateHandoff`), which stops the
    /// running daemon. A keep quit runs it after its saves, once a save past its limit (the chat
    /// composers' drafts on their way to acpmux) has landed, at most ``handoffSaveWait``; nil
    /// for every other quit.
    public var handOffAcpmux: (@MainActor () async -> Void)?
    /// The quit's step limiter: the steps past their limit still run, and the
    /// quit waits for them (``finishSaves(ends:)``).
    public var limiter: QuitStepLimiter
    /// What is left of the quit's deadline for those steps (the reply's margin
    /// kept); nil while none is armed.
    public var timeLeft: @MainActor () -> Duration?

    /// How long an End quit waits for a save step past its limit before its
    /// sessions end (it has no deadline yet): a save the daemon answers late
    /// still lands before the daemon stops.
    public static let endQuitSaveWait: Duration = .seconds(2)

    /// How long Restart to Update waits for a save step past its limit before acpmux stops: the
    /// chat pages' quit ask (`AgentPaneRelaunchWake.askLimit`, 1 s), which waits for each page's
    /// last draft write to reach acpmux. Before (2026-11-11), the handoff ran as soon as the
    /// composer step passed its 400 ms limit, and acpmux stopped under the drafts still on
    /// their way: every unsent draft was gone after the update.
    public static let handoffSaveWait: Duration = .seconds(1)

    public init(prepareWindows: @escaping @MainActor () async -> Void,
                endLocalSessions: @escaping @MainActor () async -> [EndSessionsFailure],
                confirmFailures: @escaping @MainActor ([EndSessionsFailure]) async -> QuitFailureAnswer,
                endLocalAgents: @escaping @MainActor () async -> [EndSessionsFailure],
                handOffAcpmux: (@MainActor () async -> Void)? = nil,
                stopBrowserEngines: @escaping @MainActor () async -> Void,
                limiter: QuitStepLimiter,
                timeLeft: @escaping @MainActor () -> Duration?) {
        self.prepareWindows = prepareWindows
        self.endLocalSessions = endLocalSessions
        self.confirmFailures = confirmFailures
        self.endLocalAgents = endLocalAgents
        self.stopBrowserEngines = stopBrowserEngines
        self.handOffAcpmux = handOffAcpmux
        self.limiter = limiter
        self.timeLeft = timeLeft
    }

    /// Runs the steps for a quit that `ends` the local sessions (End
    /// Sessions, End Everything) or keeps them.
    @MainActor
    public func run(ends: Bool) async {
        await prepareWindows()
        if ends {
            // A late save to the daemon lands before the daemon stops (Cloud's step ends no local data).
            await limiter.finishOverruns(within: Self.endQuitSaveWait, excluding: [QuitSaveSteps.cloudStepName])
            var failures = await endLocalAgents() + endLocalSessions()
            while !failures.isEmpty, await confirmFailures(failures) == .retry {
                failures = await endLocalAgents() + endLocalSessions()
            }
        } else if let handOffAcpmux {
            // A late draft write lands before acpmux stops for the new build (Cloud's step ends no local data).
            await limiter.finishOverruns(within: min(Self.handoffSaveWait, timeLeft() ?? Self.handoffSaveWait),
                                         excluding: [QuitSaveSteps.cloudStepName])
            await handOffAcpmux()
        }
        // A save past its limit gets what the deadline leaves less the engines' close wait, so
        // Chromium still closes its pages and CefShutdown flushes cookies and storage. A save
        // still late then runs on beside the engine stop; a closed page has no session to save,
        // so a late browser-records save writes nothing over its good record.
        let beforeEngines = (timeLeft() ?? .zero) - QuitDeadline.engineCloseWait
        await limiter.finishOverruns(within: max(.zero, beforeEngines), excluding: [QuitSaveSteps.cloudStepName])
        await stopBrowserEngines()
        // Cloud's credential cleanup (and a save the deadline already cut short) gets what is left
        // of the deadline before AppKit's reply ends the process.
        await limiter.finishOverruns(within: timeLeft() ?? .zero)
    }
}

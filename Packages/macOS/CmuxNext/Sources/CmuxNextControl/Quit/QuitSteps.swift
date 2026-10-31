public import CmuxNextDaemon
public import CmuxNextSettings

/// The answer to "Some sessions did not end" (`QuitFailureAlert`).
public enum QuitFailureAnswer: Equatable, Sendable {
    case retry
    case quitAnyway
}

/// The work between the quit decision and AppKit's reply, in order:
/// remember the choice ("Don't ask again"), save and close windows
/// (incognito workspaces close here), then, for an End choice, end the
/// local acpmux agents (except the Home Chief's), then the local terminals,
/// and stop the local daemon (End Everything deletes the local workspaces
/// but Home first). Agents end first: their tool shells must not see the
/// terminals vanish under a turn that still runs. A step of the end that fails is shown
/// with Retry and Quit Anyway (`confirmFailures`); the quit never goes on
/// silently past one. Keep never touches the daemon. The browser
/// engines stop last: Chromium's own Mac shutdown watchdog ends the
/// process with exit code 2 when CefShutdown runs past 10 s (a loaded
/// machine), so nothing the user asked for may come after it.
public struct QuitSteps {
    public var remember: @MainActor (QuitBehavior) async -> Void
    public var prepareWindows: @MainActor () async -> Void
    /// Ends the local sessions as the quit's choice says; returns every step that failed.
    public var endLocalSessions: @MainActor () async -> [EndSessionsFailure]
    /// Shows the failures and waits for Retry or Quit Anyway.
    public var confirmFailures: @MainActor ([EndSessionsFailure]) async -> QuitFailureAnswer
    /// Ends the local acpmux agents (`_acpmux/shutdown endAgents`), before
    /// the terminals; returns its failure, if any.
    public var endLocalAgents: @MainActor () async -> [EndSessionsFailure]
    public var stopBrowserEngines: @MainActor () async -> Void

    public init(remember: @escaping @MainActor (QuitBehavior) async -> Void,
                prepareWindows: @escaping @MainActor () async -> Void,
                endLocalSessions: @escaping @MainActor () async -> [EndSessionsFailure],
                confirmFailures: @escaping @MainActor ([EndSessionsFailure]) async -> QuitFailureAnswer,
                endLocalAgents: @escaping @MainActor () async -> [EndSessionsFailure],
                stopBrowserEngines: @escaping @MainActor () async -> Void) {
        self.remember = remember
        self.prepareWindows = prepareWindows
        self.endLocalSessions = endLocalSessions
        self.confirmFailures = confirmFailures
        self.endLocalAgents = endLocalAgents
        self.stopBrowserEngines = stopBrowserEngines
    }

    /// Runs the steps for a quit that `ends` the local sessions (End
    /// Sessions, End Everything) or keeps them; `remember` is the setting
    /// "Don't ask again" writes, nil when it was not asked for.
    @MainActor
    public func run(ends: Bool, remember remembered: QuitBehavior?) async {
        if let remembered { await remember(remembered) }
        await prepareWindows()
        if ends {
            var failures = await endLocalAgents() + endLocalSessions()
            while !failures.isEmpty, await confirmFailures(failures) == .retry {
                failures = await endLocalAgents() + endLocalSessions()
            }
        }
        await stopBrowserEngines()
    }
}

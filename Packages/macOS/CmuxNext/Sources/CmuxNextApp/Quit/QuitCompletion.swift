import CmuxNextDaemon
import CmuxNextSettings

/// The answer to "Some sessions did not end" (`QuitFailureAlert`).
enum QuitFailureAnswer: Equatable {
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
struct QuitSteps {
    var remember: @MainActor (QuitBehavior) async -> Void
    var prepareWindows: @MainActor () async -> Void
    /// Ends the local sessions; returns every step that failed.
    var endLocalSessions: @MainActor (QuitSessionsChoice) async -> [EndSessionsFailure]
    /// Shows the failures and waits for Retry or Quit Anyway.
    var confirmFailures: @MainActor ([EndSessionsFailure]) async -> QuitFailureAnswer
    /// Ends the local acpmux agents (`_acpmux/shutdown endAgents`), before
    /// the terminals; returns its failure, if any.
    var endLocalAgents: @MainActor () async -> [EndSessionsFailure] = { [] }
    var stopBrowserEngines: @MainActor () async -> Void
    /// The error journal's quit harvest and write (`ErrorJournalService.stop`): what frameworks
    /// (and cmux sites still on `Logger`) logged in this run, which no later launch can read. Best
    /// effort: it runs beside the other steps, off the main thread, and the quit awaits it only
    /// after the engines began to stop, under the quit's deadline (`QuitDeadline`), so it never
    /// holds up the quit.
    var harvestErrors: @MainActor () async -> Void = {}
}

enum QuitCompletion {
    @MainActor
    static func run(_ choice: QuitSessionsChoice, remember: Bool, _ steps: QuitSteps) async {
        // An OSLogStore read (seconds after a long run): beside the steps, awaited only under the
        // deadline that stopBrowserEngines arms, so it never delays the engines or the reply.
        let harvestErrors = steps.harvestErrors
        async let harvested: Void = harvestErrors()
        if remember { await steps.remember(QuitPolicy.remembered(choice)) }
        await steps.prepareWindows()
        if choice.ends {
            var failures = await steps.endLocalAgents() + steps.endLocalSessions(choice)
            while !failures.isEmpty, await steps.confirmFailures(failures) == .retry {
                failures = await steps.endLocalAgents() + steps.endLocalSessions(choice)
            }
        }
        await steps.stopBrowserEngines()
        await harvested
    }
}

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
/// machine), so nothing the user asked for may come after it. Right
/// before them, the last save runs, the quit deadline is armed and the
/// background lanes start to drain (`BackgroundWork.beginShutdown`), so
/// their block-shutdown saves run alongside the engine stop, not in front
/// of it; the quit waits for those saves after the engines have stopped,
/// still inside the deadline (Chrome's `TaskTracker` drains the same way:
/// base/task/thread_pool/task_tracker.cc).
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
    /// The last save: what changed after `prepareWindows` (drafts typed while "Some sessions did not end"
    /// waited).
    var lastSave: @MainActor () async -> Void = {}
    /// Arms the quit's hard deadline (`QuitDeadline`): from here the quit ends by it, whatever the
    /// engines and the lanes do.
    var armDeadline: @MainActor () -> Void = {}
    /// Starts draining the background lanes (`BackgroundWork.beginShutdown`); returns at once.
    var beginDrain: @MainActor () -> Void = {}
    var stopBrowserEngines: @MainActor () async -> Void
    /// Waits until every block-shutdown save has finished (`BackgroundWork.shutdown`).
    var finishDrain: @MainActor () async -> Void = {}
}

enum QuitCompletion {
    @MainActor
    static func run(_ choice: QuitSessionsChoice, remember: Bool, _ steps: QuitSteps) async {
        if remember { await steps.remember(QuitPolicy.remembered(choice)) }
        await steps.prepareWindows()
        if choice.ends {
            var failures = await steps.endLocalAgents() + steps.endLocalSessions(choice)
            while !failures.isEmpty, await steps.confirmFailures(failures) == .retry {
                failures = await steps.endLocalAgents() + steps.endLocalSessions(choice)
            }
        }
        await steps.lastSave()
        steps.armDeadline()
        steps.beginDrain()
        await steps.stopBrowserEngines()
        await steps.finishDrain()
    }
}

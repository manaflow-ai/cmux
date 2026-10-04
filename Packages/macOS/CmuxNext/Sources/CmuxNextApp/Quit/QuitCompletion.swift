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
/// local terminals and stop the local daemon (End Everything deletes the
/// local workspaces but Home first). A step of the end that fails is shown
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
    var stopBrowserEngines: @MainActor () async -> Void
}

enum QuitCompletion {
    @MainActor
    static func run(_ choice: QuitSessionsChoice, remember: Bool, _ steps: QuitSteps) async {
        if remember { await steps.remember(QuitPolicy.remembered(choice)) }
        await steps.prepareWindows()
        if choice.ends {
            var failures = await steps.endLocalSessions(choice)
            while !failures.isEmpty, await steps.confirmFailures(failures) == .retry {
                failures = await steps.endLocalSessions(choice)
            }
        }
        await steps.stopBrowserEngines()
    }
}

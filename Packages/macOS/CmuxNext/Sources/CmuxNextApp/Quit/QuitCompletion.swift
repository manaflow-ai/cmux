import CmuxNextSettings

/// The work between the quit decision and AppKit's reply, in order:
/// remember the choice ("Don't ask again"), save and close windows
/// (incognito workspaces close here), then, for an End choice, end the
/// local terminals and stop the local daemon (End Everything deletes the
/// local workspaces first). Keep never touches the daemon.
struct QuitSteps {
    var remember: @MainActor (QuitBehavior) async -> Void
    var prepareWindows: @MainActor () async -> Void
    var endLocalSessions: @MainActor (QuitSessionsChoice) async -> Void
}

enum QuitCompletion {
    @MainActor
    static func run(_ choice: QuitSessionsChoice, remember: Bool, _ steps: QuitSteps) async {
        if remember { await steps.remember(QuitPolicy.remembered(choice)) }
        await steps.prepareWindows()
        if choice.ends { await steps.endLocalSessions(choice) }
    }
}

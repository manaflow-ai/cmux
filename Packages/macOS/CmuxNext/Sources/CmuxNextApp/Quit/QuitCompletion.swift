import CmuxNextSettings

/// The work between the quit decision and AppKit's reply, in order:
/// remember the choice ("Don't ask again"), save and close windows
/// (incognito workspaces close here), then, for End, end the local
/// terminals and stop the local daemon. Keep never touches the daemon.
struct QuitSteps {
    var remember: @MainActor (QuitBehavior) async -> Void
    var prepareWindows: @MainActor () async -> Void
    var endLocalSessions: @MainActor () async -> Void
}

enum QuitCompletion {
    @MainActor
    static func run(_ choice: QuitSessionsChoice, remember: Bool, _ steps: QuitSteps) async {
        if remember { await steps.remember(QuitPolicy.remembered(choice)) }
        await steps.prepareWindows()
        if choice == .end { await steps.endLocalSessions() }
    }
}

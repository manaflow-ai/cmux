import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Perf-lead issue 11 (every create commits in < 10 ms on the key, visible in the first frame):
/// a new workspace its window claimed (Cmd-N's stand-in, a terminal workspace, Duplicate
/// Workspace, a pane moved to a new workspace) is selected by the membership reconcile in the
/// turn the store lists it, but the window swapped its content only on its observation hop, a
/// main-actor job later: the frame the turn committed could still draw the old workspace under
/// the new selection (Cmd-N: frame 1 p50, up to frame 3 idle, instant-new-surfaces.md). A switch
/// already swaps in its own turn (`WindowManager.show(workspaceID:in:from:)`); a create must too.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CreateShowsInItsTurnTests {
    /// What the window selected, what it drew, and whether the selected workspace was still the
    /// intent's provisional stand-in, at the end of each turn the store reported a changed
    /// workspace list in.
    @MainActor private final class Turns {
        var seen: [(selected: String?, shown: String?, provisional: Bool)] = []
    }

    @Test func aNewWorkspaceShowsInTheTurnItsWindowSelectsIt() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let store = services.daemon.store
        // This Mac hosts the New Tab page, so Cmd-N takes the instant path: the stand-in is listed
        // and selected inside the intent's turn, through `store.onWorkspaceListChanged`. Without a
        // page the create goes through FirstTabHold, whose release reconciles directly and never
        // reaches the wrapped hook, so the test would not measure the fix.
        services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-in-turn")
        try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let before = controller.state.workspaceID
        let turns = Turns()
        // The window manager's own hook (the membership reconcile) runs first, as it always does.
        let reconcile = store.onWorkspaceListChanged
        store.onWorkspaceListChanged = {
            reconcile?()
            let selected = controller.state.workspaceID
            let provisional = store.workspaces.first { $0.id == selected }?.isProvisional == true
            turns.seen.append((selected, controller.content?.workspace.id, provisional))
        }

        // A person's Cmd-N in the window (shown there, `focus` defaults to true).
        _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("in-turn")]))
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
            controller.state.workspaceID != before && controller.content?.workspace.id == controller.state.workspaceID
        }
        store.onWorkspaceListChanged = reconcile
        let created = controller.state.workspaceID
        let seen = turns.seen
        await launched.stop()

        #expect(created != before, "the new workspace was never selected")
        let selecting = seen.filter { $0.selected == created }
        #expect(!selecting.isEmpty, "no store turn selected the new workspace: \(seen)")
        // The first selecting turn is the intent's own: the workspace is still the stand-in there.
        #expect(selecting.first?.provisional == true,
                "the first turn that selected the new workspace was not the intent's (not provisional): \(seen)")
        #expect(selecting.allSatisfy { $0.shown == created },
                "the window selected the new workspace but drew \(selecting.map { $0.shown ?? "nothing" }) at the end of that turn")
    }
}

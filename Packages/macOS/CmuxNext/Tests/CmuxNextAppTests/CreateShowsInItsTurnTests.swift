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
    /// What the window selected and what it drew at the end of each turn the store reported a
    /// changed workspace list in.
    @MainActor private final class Turns {
        var seen: [(selected: String?, shown: String?)] = []
    }

    @Test func aNewWorkspaceShowsInTheTurnItsWindowSelectsIt() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let store = services.daemon.store
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let before = controller.state.workspaceID
        let turns = Turns()
        // The window manager's own hook (the membership reconcile) runs first, as it always does.
        let reconcile = store.onWorkspaceListChanged
        store.onWorkspaceListChanged = {
            reconcile?()
            turns.seen.append((controller.state.workspaceID, controller.content?.workspace.id))
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
        #expect(selecting.allSatisfy { $0.shown == created },
                "the window selected the new workspace but drew \(selecting.map { $0.shown ?? "nothing" }) at the end of that turn")
    }
}

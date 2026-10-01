import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Reopen Closed Workspace: it picks the newest closed workspace from the
/// daemon's closed history (closed tabs stay for Reopen Closed Tab), and
/// shows the workspace the daemon recreated once the mirror lists it.
@MainActor
struct ReopenClosedWorkspaceTests {
    typealias Item = DaemonConnection.ClosedItem

    @Test func picksTheNewestClosedWorkspaceAndSkipsTabs() throws {
        let items = [
            Item(id: "closed_tab", kind: .tab, name: "logs", workspaceID: "ws_a"),
            Item(id: "closed_new", kind: .workspace, name: "scratch"),
            Item(id: "closed_old", kind: .workspace, name: "older"),
        ]
        #expect(try WorkspaceHandlers.newestClosedWorkspace(in: items).id == "closed_new")
    }

    @Test func refusesWhenNoWorkspaceWasClosed() {
        let items = [Item(id: "closed_tab", kind: .tab), Item(id: "closed_screen", kind: .screen)]
        #expect(throws: ActionFailure(message: RefusalStrings.noRecentlyClosedWorkspace)) {
            try WorkspaceHandlers.newestClosedWorkspace(in: items)
        }
        #expect(throws: ActionFailure(message: RefusalStrings.noRecentlyClosedWorkspace)) {
            try WorkspaceHandlers.newestClosedWorkspace(in: [])
        }
    }

    @Test func waitsForTheReopenedWorkspaceToReachTheMirror() async throws {
        let store = DaemonStore()
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = store.apply(.connected(identity, generationChanged: false))
        let wait = Task { await WorkspaceHandlers.reopenedWorkspace(ResourceID(rawValue: "ws_w"), in: store) }
        await Task.yield()
        store.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/tmp/a")]))
        let found = await wait.value
        #expect(found != nil)
        #expect(found == store.workspaces.first?.id)
    }

    @Test func givesUpWhenTheWorkspaceNeverArrives() async {
        let store = DaemonStore()
        let found = await WorkspaceHandlers.reopenedWorkspace(ResourceID(rawValue: "ws_missing"), in: store, timeout: .milliseconds(50))
        #expect(found == nil)
    }
}

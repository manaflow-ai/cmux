import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// One order for every reader (sidebar owner, 2026-10-24): a window's membership changes only when a workspace joins
/// or leaves it, so after a move (`workspace move --index 0`, a drag) `window list` and Search Tabs still listed the
/// window's workspaces in their old order while the sidebar showed the new one. Both read the window's
/// `ControlWindowInfo.workspaceIDs` from the control topology; it now follows the sidebar's `workspaceOrder`.
@MainActor @Suite(.serialized)
struct WindowListFollowsSidebarOrderTests {
    static let keys = ["k0", "k1", "k2", "k3", "k4"]

    static func tree(order: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
        })
        tree.personal = PersonalState(sessions: [SessionRecord(id: "s-local")], workspaces: order.enumerated().map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0)
        })
        return tree
    }

    @Test func aMoveShowsInTheWindowListAndTabSearchOrder() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(order: Self.keys))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: Self.keys, frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        controller.sidebar.sameTurn.syncNow(rows: true)
        let listed = { ControlSnapshotPublisher.topology(services).windows.first { $0.id == controller.state.id }?.workspaceIDs ?? [] }
        #expect(listed() == Self.keys)

        // k3 moves to the top: the personal order changes, the window's membership does not.
        let moved = ["k3", "k0", "k1", "k2", "k4"]
        store.apply(snapshot: Self.tree(order: moved))
        controller.sidebar.sameTurn.syncNow(rows: true)
        #expect(controller.sidebar.model.allWorkspaces.map(\.id.rawValue) == moved, "the fixture's sidebar did not show the move")
        #expect(listed() == moved, "window list kept the order from before the move")
        // Search Tabs ranks workspaces by the same field (`TabSearchEntries`): the window's first workspace ranks first.
        let window = try #require(ControlSnapshotPublisher.topology(services).windows.first { $0.id == controller.state.id })
        #expect(window.workspaceIDs.first == "k3")
    }
}

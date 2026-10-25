import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// Each mounted workspace has a node under its window's node (p06-scheduler-023, Chromium
/// `content::Visibility`): parking makes it hidden, unparking or a drawing companion makes it
/// visible, and a workspace not mounted in a window has no node.
@MainActor struct WorkspaceVisibilityNodeTests {
    private static func connected(_ session: String) throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"\#(session)","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func onePane() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func workspaces(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    @Test func parkThenUnparkFlipsTheNodeAndTeardownRemovesIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected("visibility-node-test"))
        store.apply(snapshot: Self.onePane())
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let windowNode = VisibilityNode(root: "window", own: .visible)

        let unmounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        #expect(unmounted.visibility == nil, "a workspace not mounted in a window has no node")
        unmounted.teardown()

        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state,
                                                 window: windowNode)
        defer { withExtendedLifetime((services, state)) { content.teardown() } }
        let node = try #require(content.visibility)
        #expect(node.parent === windowNode)
        #expect(node.isVisible)
        var flips: [Visibility] = []
        let token = node.subscribe(owner: "test") { flips.append($0) }
        defer { token.cancel() }

        content.park(serial: 1)
        #expect(node.effective == .hidden)
        content.unpark()
        #expect(node.effective == .visible)
        #expect(flips == [.hidden, .visible], "park then unpark flips the node twice")

        content.park(serial: 2)
        content.followAttention()
        #expect(node.effective == .visible, "a parked companion that draws is visible")
        #expect(flips == [.hidden, .visible, .hidden, .visible])

        content.park(serial: 3)
        content.park(serial: 3)
        #expect(flips.count == 5, "parking a parked workspace again does not notify")

        content.teardown()
        #expect(content.visibility == nil, "a torn-down workspace has no node")
        #expect(node.parent == nil, "teardown takes the node out of the window's tree")
    }

    @Test func aWindowSwitchHidesTheParkedWorkspaceAndShowsTheNewOne() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try Self.connected("s-local")
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.workspaces(["k1", "k2"]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"visibility-switch","workspace_key":"k1"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ["k1", "k2"]
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        controller.showWorkspace(requested: state.workspaceID)
        let first = try #require(controller.content)
        let firstNode = try #require(first.visibility)
        #expect(firstNode.parent === controller.visibility)
        #expect(firstNode.isVisible)

        state.showWorkspace("k2")
        controller.showWorkspace(requested: state.workspaceID)
        let second = try #require(controller.content)
        try #require(second !== first)
        #expect(firstNode.effective == .hidden, "the parked workspace is hidden in the switch's turn")
        #expect(second.visibility?.isVisible == true)

        state.showWorkspace("k1")
        controller.showWorkspace(requested: state.workspaceID)
        #expect(controller.content === first)
        #expect(firstNode.isVisible, "unparking shows the same node again")
        #expect(second.visibility?.effective == .hidden)
    }
}

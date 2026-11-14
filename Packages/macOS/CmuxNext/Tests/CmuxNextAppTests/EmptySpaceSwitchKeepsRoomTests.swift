import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// #31502: a switch into a space with no workspaces fell back to the previous space in 2 of 3
/// fleet runs. `switchProfile` entered the empty space and started its first workspace's create
/// in a separate `Task`; the window was claimed ("waiting for its new workspace") only when that
/// create ran, so a selection repair in between (any store event or reconcile) found the space
/// empty and nothing waiting, and moved the window back. The window must wait from the switch's
/// own turn, and stop waiting when the create fails.
@MainActor @Suite(.serialized)
struct EmptySpaceSwitchKeepsRoomTests {
    @Test func aRepairInTheSwitchTurnKeepsTheEmptySpaceUntilItsCreateFails() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let empty = ProfileID(rawValue: "room-empty"), full = ProfileID(rawValue: "room-full")
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1", screens: []),
        ])
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: [ProfileSnapshot(id: full, name: "Full", index: 0), ProfileSnapshot(id: empty, name: "Empty", index: 1)],
            pins: [WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), profile: full)],
            workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
        store.apply(snapshot: tree)

        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let state = controller.state
        #expect(state.profileID == full)

        services.windows.switchProfile(empty, in: state)
        #expect(state.profileID == empty)
        // A selection repair in the switch's own turn, before its create ran: the window waits there.
        services.windows.repairSelections(previous: services.windows.membersByWindow)
        #expect(state.profileID == empty, "the window left the empty space before its first workspace was created")

        // This app has no daemon connection, so the create fails: the window stops waiting and shows the
        // space it has workspaces in again, not an empty one forever.
        let deadline = ContinuousClock.now + .seconds(10)
        while state.profileID == empty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.profileID == full, "a failed create left the window in the empty space")
        #expect(!services.windows.claims.pending.values.contains(state.id), "a failed create left its claim")
    }

    /// A switch into a space with no workspace changes no content (the window waits for the space's first
    /// workspace), so the content swap that carries the sidebar's rows pass never ran: the sidebar listed the
    /// space the window left for one more turn. The rows follow the space in the switch's own turn.
    @Test func theSidebarListsAnEmptySpaceInTheSwitchsOwnTurn() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let empty = ProfileID(rawValue: "room-empty"), full = ProfileID(rawValue: "room-full")
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1", screens: []),
        ])
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: [ProfileSnapshot(id: full, name: "Full", index: 0), ProfileSnapshot(id: empty, name: "Empty", index: 1)],
            pins: [WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), profile: full)],
            workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
        store.apply(snapshot: tree)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let state = controller.state, sidebar = controller.sidebar
        let fullIDs = Set(store.workspaces.map(\.id))
        let listsFull = {
            sidebar.container.sidebarView.list.displayed.rows.contains { if case let .workspace(id) = $0.key { fullIDs.contains(id.rawValue) } else { false } }
        }
        controller.showWorkspace(requested: state.workspaceID)
        var turns = 0
        let pump = { for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date()) } } // a sync context: the main run loop's turns
        while !(sidebar.model.activeProfileID?.rawValue == full.rawValue && listsFull()), turns < 2000 {
            pump()
            try await Task.sleep(for: .milliseconds(1))
            turns += 1
        }
        #expect(sidebar.model.activeProfileID?.rawValue == full.rawValue && listsFull(), "the window does not start on its space's rows after \(turns) turns")

        services.windows.switchProfile(empty, in: state)
        #expect(state.profileID == empty)
        #expect(sidebar.model.activeProfileID?.rawValue == empty.rawValue,
                "the sidebar still marks \(sidebar.model.activeProfileID?.rawValue ?? "no space") in the switch's turn")
        #expect(!listsFull(), "the sidebar still lists the workspace of the space the window left in the switch's turn")
    }
}

import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
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
}

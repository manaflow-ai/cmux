import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Home needed two clicks (nightly NEXT, 2026-10-21): `home.show` runs `WindowManager.show(workspaceID:in:)`
/// on the home workspace. When that workspace is in another room and no window lists it yet, the first
/// call only moved it into the window: the window's selection repair read the room it was in, where the
/// workspace does not show, so the window kept its old workspace. The second call found it a member and
/// switched the room. One call must show it, in its room.
@MainActor @Suite(.serialized)
struct ShowWorkspaceOtherRoomTests {
    @Test func showingAnUnplacedWorkspaceOfAnotherRoomShowsItOnTheFirstCall() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let rooms = [ProfileID(rawValue: "room0"), ProfileID(rawValue: "room1")]
        let keys = ["k0", "k1"]
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
        })
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: rooms.enumerated().map { ProfileSnapshot(id: $1, name: "Space \($0)", index: $0) },
            pins: keys.enumerated().map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), profile: rooms[$0]) },
            workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        store.apply(snapshot: tree)

        // The window lists only k1 (room1); k0 (room0, the home workspace's case) is in no window.
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let state = controller.state
        #expect(state.workspaceID == "k1")
        #expect(state.profileID == rooms[1])
        #expect(services.windows.registry.value.owner(of: "k0") == nil)

        services.windows.show(workspaceID: "k0", in: state)

        #expect(state.workspaceID == "k0")
        #expect(state.profileID == rooms[0])
    }
}

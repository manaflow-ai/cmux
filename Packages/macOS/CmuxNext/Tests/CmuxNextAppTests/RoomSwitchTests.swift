import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Switching a window between rooms through `WindowManager`
/// (plans/cmux-next/data-model.md 4): the window lists only its current
/// room's workspaces, remembers the last one per room, follows a selected
/// workspace into its room, and falls back when its room loses its last
/// workspace or is deleted. Windows are never put on screen.
@MainActor
struct RoomSwitchTests {
    static let keys = (1...3).map { WorkspaceKey(rawValue: "7a1e8f0a-3c2b-4a19-8e7d-6b5a4c3d2e1\($0)") }
    static let session = "11111111-2222-4333-8444-555555555555"
    static let work: ProfileID = "prof_work"

    private static func id(_ index: Int) -> String { keys[index - 1].rawValue }

    /// Default follows this session; w3 is pinned to Work.
    private static func apply(_ services: AppServices, keys: [WorkspaceKey], rooms: [ProfileID] = [.defaultProfile, work],
                              pins: [WorkspaceKey: ProfileID] = [keys[2]: work]) {
        let snapshots = keys.map { key in
            let index = Self.keys.firstIndex(of: key)! + 1
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index)), key: key, name: "w\(index)")
        }
        var tree = DaemonTree(registryID: session, workspaceRevision: 100, workspaces: snapshots)
        tree.personal = PersonalState(
            revision: 1,
            profiles: rooms.enumerated().map { index, room in
                ProfileSnapshot(id: room, name: room.rawValue, index: index, follows: room == .defaultProfile ? [session] : [])
            },
            pins: pins.map { WorkspacePin(sessionID: session, workspaceKey: $0.key, profile: $0.value) })
        services.daemon.store.apply(snapshot: tree)
    }

    private static func services() -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        apply(services, keys: keys)
        return services
    }

    private static func visible(_ services: AppServices, _ state: WindowState) -> [String] {
        WindowProfiles.visible(services.windows.registry.members(of: state.id), profile: state.profileID, machines: services.machines)
    }

    @Test func aSwitchShowsTheRoomAndRestoresTheLastWorkspace() throws {
        let services = Self.services()
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        let state = window.state
        services.windows.select(Self.id(2), in: state)
        #expect(Self.visible(services, state) == [Self.id(1), Self.id(2)])
        services.windows.switchProfile(Self.work, in: state)
        #expect(state.profileID == Self.work)
        #expect(state.workspaceID == Self.id(3))
        #expect(Self.visible(services, state) == [Self.id(3)])
        services.windows.switchProfile(.defaultProfile, in: state)
        #expect(state.workspaceID == Self.id(2))
        window.window?.close()
    }

    @Test func selectingAWorkspaceOfAnotherRoomFollowsIt() throws {
        let services = Self.services()
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        services.windows.select(Self.id(3), in: window.state)
        #expect(window.state.profileID == Self.work)
        window.window?.close()
    }

    @Test func aRoomThatLosesItsLastWorkspaceFallsBack() throws {
        let services = Self.services()
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        services.windows.reconcileMembership()
        services.windows.switchProfile(Self.work, in: window.state)
        // Another client closes w3, Work's only workspace here.
        Self.apply(services, keys: Array(Self.keys.prefix(2)))
        #expect(window.state.profileID == .defaultProfile)
        #expect(window.state.workspaceID == Self.id(1), "\(String(describing: window.state.workspaceID))")
        #expect(services.windows.controllers.count == 1)
        window.window?.close()
    }

    @Test func aDeletedRoomFallsBackToDefault() throws {
        let services = Self.services()
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        services.windows.switchProfile(Self.work, in: window.state)
        Self.apply(services, keys: Self.keys, rooms: [.defaultProfile], pins: [:])
        services.windows.reconcileMembership()
        #expect(window.state.profileID == .defaultProfile)
        #expect(Self.visible(services, window.state).count == 3)
        window.window?.close()
    }

    @Test func withoutPersonalStateEveryWorkspaceShows() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let snapshots = Self.keys.enumerated().map { WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0.offset + 1)), key: $0.element, name: "w") }
        services.daemon.store.apply(snapshot: DaemonTree(registryID: Self.session, workspaceRevision: 1, workspaces: snapshots))
        let window = try #require(services.windows.openWindow(workspaces: Self.keys.map(\.rawValue)))
        #expect(Self.visible(services, window.state).count == 3)
        window.window?.close()
    }
}

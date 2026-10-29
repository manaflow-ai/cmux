import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// "could u guys also now work on the per space pins and groups? ... there's also other ergo wrt new
/// windows being like new spaces ... this could legit make our thing more useful than chrome by
/// having windows be switchable in this way" (Leo 2026-10-29). Move Space to This Window
/// (`space.bringHere`) takes one space's workspaces out of the other windows; Merge All Windows
/// (`window.mergeAll`) takes every other normal window's workspaces. Both run the real registry
/// transition (`WindowManager.bringSpace`, `mergeWindows`) over a home daemon with two spaces
/// (pins), as `ShowWorkspaceOtherRoomTests`.
@MainActor @Suite(.serialized, .closesItsWindows)
struct GatherWindowsTests {
    static let rooms = [ProfileID(rawValue: "room0"), ProfileID(rawValue: "room1")]
    /// k0, k1 in room0; k2, k3 in room1.
    static let keys = ["k0", "k1", "k2", "k3"]
    static func room(of key: String) -> ProfileID { rooms[keys.firstIndex(of: key)! / 2] }

    static func services() throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
        })
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: rooms.enumerated().map { ProfileSnapshot(id: $1, name: "Space \($0)", index: $0) },
            pins: keys.map { WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $0), profile: room(of: $0)) },
            workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
        store.apply(snapshot: tree)
        services.windows.ordersWindowsIn = false
        return services
    }

    static func open(_ workspaces: [String], _ services: AppServices, id: String = UUID().uuidString.lowercased(),
                     incognito: Bool = false) throws -> WindowController {
        try #require(services.windows.openWindow(id: id, workspaces: workspaces, frame: CGRect(x: 120, y: 120, width: 900, height: 600),
                                                 incognito: incognito))
    }

    static func closeAll(_ services: AppServices) {
        services.windows.incognitoSpaces = [:]
        for controller in services.windows.controllers {
            controller.teardown()
            controller.window?.close()
        }
    }

    /// The source window kept only room1's workspaces: they all move, it closes, and the window
    /// shows room1 with the workspace the source showed there.
    @Test func bringingASpaceHereClosesTheWindowItEmptied() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "k3"], services)
        services.windows.select("k3", in: there.state)
        #expect(there.state.profileID == Self.rooms[1])

        try services.windows.bringSpace(Self.rooms[1], into: here.state)

        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id) == nil, "the emptied window stayed")
        #expect(registry.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k2", "k3"])
        #expect(here.state.profileID == Self.rooms[1])
        #expect(here.state.workspaceID == "k3", "the space's last shown workspace was not kept")
    }

    /// Only the space's workspaces move: a source window that keeps another space's stays open.
    @Test func aSourceWindowThatKeepsOtherSpacesStaysOpen() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0", "k2"], services), there = try Self.open(["k1", "k3"], services)

        try services.windows.bringSpace(Self.rooms[1], into: here.state)

        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id)?.workspaceIDs == ["k1"], "a workspace of another space moved")
        #expect(registry.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k2", "k3"])
        #expect(here.state.profileID == Self.rooms[1])
        #expect(there.state.profileID == Self.rooms[0])
        #expect(there.state.workspaceID == "k1")
    }

    /// An incognito space, or an incognito window, takes part in no move (rule 2).
    @Test func incognitoIsRefused() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2"], services)
        let before = services.windows.registry.value

        services.windows.incognitoSpaces["another-window"] = Self.rooms[1]
        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[1], into: here.state) }
        services.windows.incognitoSpaces = [here.state.id: Self.rooms[0]]
        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[1], into: here.state) }
        #expect(throws: ActionFailure.self) { try services.windows.mergeWindows(into: here.state) }
        services.windows.incognitoSpaces = [:]

        #expect(services.windows.registry.value == before, "a refused move changed windows")
        #expect(here.state.profileID == Self.rooms[0])
        #expect(there.state.workspaceID == "k2")
    }

    /// Every other normal window's workspaces move here and keep their space; those windows close,
    /// this one keeps its space and selection, and an incognito window is left alone.
    @Test func mergingAllWindowsKeepsEachWorkspacesSpace() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services)
        let second = try Self.open(["k2"], services), third = try Self.open(["k1"], services)
        let incognito = try Self.open(["k3"], services, incognito: true)
        #expect(services.windows.isIncognito(window: incognito.state.id))

        try services.windows.mergeWindows(into: here.state)

        let registry = services.windows.registry.value
        #expect(registry.window(second.state.id) == nil)
        #expect(registry.window(third.state.id) == nil)
        #expect(registry.window(incognito.state.id)?.workspaceIDs == ["k3"], "the incognito window was merged")
        let members = registry.window(here.state.id)?.workspaceIDs ?? []
        #expect(members.sorted() == ["k0", "k1", "k2"])
        #expect(here.state.profileID == Self.rooms[0])
        #expect(here.state.workspaceID == "k0")
        #expect(WindowProfiles.visible(members, profile: Self.rooms[0], machines: services.machines).sorted() == ["k0", "k1"])
        #expect(WindowProfiles.visible(members, profile: Self.rooms[1], machines: services.machines) == ["k2"])
        // Switching to room1 shows what the merged window showed there.
        #expect(here.state.profileWorkspaces[Self.rooms[1]] == "k2")
    }
}

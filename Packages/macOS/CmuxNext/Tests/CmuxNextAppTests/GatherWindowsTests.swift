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

    static func services(storeHome: Bool = false) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        // Each workspace has one pane with a terminal; `wh` is a window's own Home (Home's page tab first, a
        // terminal beside it), in no space.
        func screen(_ index: Int, _ tabs: [TabSnapshot]) -> [ScreenSnapshot] {
            let raw = UInt64(100 + index), pane = PaneID(rawValue: raw)
            return [ScreenSnapshot(id: ScreenID(rawValue: raw), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])]
        }
        var page = TabSnapshot(surface: 900, kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: WorkspaceModel.homeDockPage)
        var workspaces = keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key,
                              screens: screen(index, [TabSnapshot(surface: SurfaceID(rawValue: UInt64(200 + index)))]))
        }
        workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9), key: WorkspaceKey(rawValue: "wh"), name: "Home",
                                            screens: screen(9, [page, TabSnapshot(surface: 209)])))
        if storeHome { // the store's own Home (`kind` home), in no space
            var home = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 10), key: WorkspaceKey(rawValue: "hs"), name: "Home",
                                         screens: screen(10, [TabSnapshot(surface: 210)]))
            home.kind = "home"
            workspaces.append(home)
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: workspaces)
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

    /// A closed window is not "showing" its space: its selection never beats the space's remembered
    /// workspace.
    @Test func aClosedWindowsSelectionIsNotTheSpacesLastShown() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "k3"], services)
        services.windows.select("k3", in: there.state)
        here.state.profileWorkspaces[Self.rooms[1]] = "k2"
        services.windows.transition { $0.close(there.state.id) }
        #expect(services.windows.registry.value.window(there.state.id)?.isOpen == false)

        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        #expect(here.state.workspaceID == "k2", "a closed window's selection won over the remembered workspace")
    }

    /// A CLI or MCP run without focus permission moves the space's workspaces but leaves the
    /// window on its own space and selection.
    @Test func bringingASpaceWithoutFocusPermissionKeepsTheView() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0", "k1"], services), there = try Self.open(["k2", "k3"], services)
        services.windows.select("k1", in: here.state)
        #expect(here.state.profileID == Self.rooms[0])

        try ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            try services.windows.bringSpace(Self.rooms[1], into: here.state)
        }

        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id) == nil, "the emptied window stayed")
        #expect(registry.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k1", "k2", "k3"])
        #expect(here.state.profileID == Self.rooms[0], "the run switched the window's space")
        #expect(here.state.workspaceID == "k1", "the run changed the window's selection")
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

    /// A workspace no session reports yet (a remote machine still connecting or paused) has no
    /// known space, so `visible` shows it in every space. It is not moved with the space: it stays
    /// in its window, which therefore stays open.
    @Test func anUnresolvedWorkspaceStaysInItsWindow() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "remote-unresolved"], services)

        try services.windows.bringSpace(Self.rooms[1], into: here.state)

        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id)?.workspaceIDs == ["remote-unresolved"], "an unresolved workspace moved with the space")
        #expect(registry.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k2"])
        #expect(here.state.profileID == Self.rooms[1])
    }

    /// A window with a workspace still being created (claimed, a sidebar placement, a queued
    /// create, a provisional row) gives nothing up: its pending placement may anchor on a moving
    /// workspace or its window may close, so the move is refused and nothing changes.
    @Test func aWindowStillCreatingAWorkspaceIsNotGathered() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2"], services)
        let other = try Self.open(["k1", "k3"], services)
        services.windows.claimNew(workspaceID: "k-new-1", window: there.state.id)
        let before = services.windows.registry.value

        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[1], into: here.state) }
        #expect(throws: ActionFailure.self) { try services.windows.mergeWindows(into: here.state) }
        #expect(services.windows.registry.value == before, "a refused move changed windows")
        #expect(here.state.profileID == Self.rooms[0])

        services.windows.claims.pending["k-new-1"] = nil
        services.windows.pendingPlacements["k-new-2"] = PendingPlacement(window: there.state.id, slot: nil, byDefault: nil, then: nil)
        #expect(throws: ActionFailure.self) { try services.windows.mergeWindows(into: here.state) }
        services.windows.pendingPlacements["k-new-2"] = nil

        // A window the move leaves open (k1 stays in `other`) but takes k3 from: its pending placement may anchor on k3.
        services.windows.pendingPlacements["k-new-3"] = PendingPlacement(window: other.state.id, slot: nil, byDefault: nil, then: nil)
        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[1], into: here.state) }
        #expect(services.windows.registry.value == before, "a refused move changed windows")
        services.windows.pendingPlacements["k-new-3"] = nil
        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id) == nil)
        #expect(registry.window(other.state.id)?.workspaceIDs == ["k1"])
    }

    /// A window's own Home stays with its window: moved next to another window's Home it would be
    /// closed as a surplus Home, with the terminals beside it. Merge All closes the window it is in
    /// (terminals keep running, as Close Other Windows); Move Space leaves it where it is.
    @Test func aWindowsOwnHomeStaysWithItsWindow() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        #expect(services.workspace(id: "wh")?.isWindowHome == true)
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "wh"], services)

        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        #expect(services.windows.registry.value.window(here.state.id)?.workspaceIDs.contains("wh") == false, "Move Space took a window's Home")
        #expect(services.windows.registry.value.window(there.state.id)?.workspaceIDs == ["wh"])

        try services.windows.mergeWindows(into: here.state)
        let registry = services.windows.registry.value
        #expect(registry.window(here.state.id)?.workspaceIDs.contains("wh") == false, "Merge All took a window's Home")
        #expect(registry.window(there.state.id)?.isOpen != true, "the merged window stayed open")
        #expect(services.workspace(id: "wh") != nil, "the merged window's Home was closed")
    }

    /// The store's Home stays in its window too: moved beside the destination's own Home, one of the two would be out of reach.
    @Test func theStoresHomeStaysWithItsWindow() throws {
        let services = try Self.services(storeHome: true)
        defer { Self.closeAll(services) }
        #expect(services.workspace(id: "hs")?.isAnyHome == true)
        let here = try Self.open(["k0", "wh"], services), there = try Self.open(["k2", "hs"], services)
        services.windows.select("k2", in: there.state)

        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        #expect(services.windows.registry.value.window(here.state.id)?.workspaceIDs.contains("hs") == false, "Move Space took the store's Home")
        #expect(services.windows.registry.value.window(there.state.id)?.workspaceIDs.contains("hs") == true)

        try services.windows.mergeWindows(into: here.state)
        #expect(services.windows.registry.value.window(here.state.id)?.workspaceIDs.contains("hs") == false, "Merge All took the store's Home")
    }

    /// Nothing to move but another window's Home: the plain switch it falls back to leaves that Home there.
    @Test func theFallbackSwitchLeavesAnotherWindowsHome() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "wh"], services)
        services.windows.select("k2", in: there.state)
        #expect(WindowProfiles.visible(["wh"], profile: .defaultProfile, machines: services.machines) == ["wh"])

        try services.windows.bringSpace(.defaultProfile, into: here.state)
        let registry = services.windows.registry.value
        #expect(registry.window(here.state.id)?.workspaceIDs.contains("wh") == false, "the fallback switch took a window's Home")
        #expect(registry.window(there.state.id)?.workspaceIDs.contains("wh") == true)
    }

    /// Browser tabs a window keeps itself (a daemon without frontend browser tabs) are keyed by pane
    /// id, which can repeat across machines, and die with their window: a move that takes a workspace
    /// out of such a window is refused and nothing changes. A window that gives nothing up is no bar.
    @Test func aWindowKeepingItsOwnBrowserTabsIsNotGathered() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2"], services)
        let pane = try #require(services.workspace(id: "k2")?.screens.first?.panes.first?.id)
        let tab = LocalBrowserTab.make(url: URL(string: "https://example.com"))
        there.state.localBrowserTabs[pane] = [tab]
        let before = services.windows.registry.value

        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[1], into: here.state) }
        #expect(throws: ActionFailure.self) { try services.windows.mergeWindows(into: here.state) }
        #expect(services.windows.registry.value == before, "a refused move changed windows")
        #expect(there.state.localBrowserTabs[pane] == [tab])

        // Nor into a window that keeps its own browser tabs: a moved pane could share one's pane id.
        there.state.localBrowserTabs[pane] = []
        here.state.localBrowserTabs[pane] = [tab]
        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[1], into: here.state) }
        #expect(throws: ActionFailure.self) { try services.windows.mergeWindows(into: here.state) }
        #expect(services.windows.registry.value == before, "a refused move changed windows")
        here.state.localBrowserTabs[pane] = []

        // A window that keeps tabs but gives nothing up (room0's k1 stays) does not block Move Space.
        there.state.localBrowserTabs[pane] = []
        let other = try Self.open(["k1"], services)
        other.state.localBrowserTabs["another-pane"] = [tab]
        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        #expect(services.windows.registry.value.window(here.state.id)?.workspaceIDs.sorted() == ["k0", "k2"])
        #expect(other.state.localBrowserTabs["another-pane"] == [tab])
    }

    /// Merge All moves only workspaces a session reports: one not reported yet (a remote machine
    /// connecting, a Home not mirrored yet) stays in its window, which closes with it.
    @Test func mergingLeavesUnresolvedWorkspacesInTheirWindow() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "remote-unresolved"], services)

        try services.windows.mergeWindows(into: here.state)
        let registry = services.windows.registry.value
        #expect(registry.window(here.state.id)?.workspaceIDs.contains("remote-unresolved") == false, "an unresolved workspace moved")
        #expect(registry.window(here.state.id)?.workspaceIDs.contains("k2") == true)
        #expect(registry.window(there.state.id)?.isOpen != true, "the merged window stayed open")
    }

    /// Tabs a window keeps itself never block a move that moves nothing (a plain space switch), and a
    /// window the registry does not list yet (the launch window) gathers nothing: refused, nothing closes.
    @Test func noOpAndUnregisteredGathers() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k1"], services)
        here.state.localBrowserTabs["a-pane"] = [LocalBrowserTab.make(url: nil)]
        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        #expect(here.state.profileID == Self.rooms[1], "a move with nothing to move did not switch the space")

        let before = services.windows.registry.value
        let unregistered = WindowState()
        #expect(throws: ActionFailure.self) { try services.windows.bringSpace(Self.rooms[0], into: unregistered) }
        #expect(throws: ActionFailure.self) { try services.windows.mergeWindows(into: unregistered) }
        #expect(services.windows.registry.value == before, "a gather into an unregistered window changed windows")
        #expect(services.windows.registry.value.window(there.state.id)?.isOpen == true)
    }

    /// A window known incognito only by its space (`incognitoSpaces`, before the registry flag) is
    /// no source either: its workspaces stay and it stays open.
    @Test func aWindowOnAnIncognitoSpaceIsNoSource() throws {
        let services = try Self.services()
        defer { Self.closeAll(services) }
        let here = try Self.open(["k0"], services), there = try Self.open(["k2", "k3"], services)
        services.windows.incognitoSpaces[there.state.id] = ProfileID(rawValue: "incognito-there")

        try services.windows.bringSpace(Self.rooms[1], into: here.state)
        try services.windows.mergeWindows(into: here.state)
        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id)?.workspaceIDs == ["k2", "k3"], "an incognito window's workspace moved")
        #expect(registry.window(there.state.id)?.isOpen == true)
        #expect(registry.window(here.state.id)?.workspaceIDs.contains { ["k2", "k3"].contains($0) } == false)
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

import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Pinned workspaces as layout tiles (PINNED-ITEMS-END-TO-END P2): once the
/// layout owner serves `sidebar-layout-v1`, Pin Workspace writes the
/// qualified `<session>:ws_…` ref into `sec_pinned`, the list leaves the row
/// out (its place stays, so unpin returns it there), the tile draws the
/// workspace and carries the one selection. Without the owner the legacy
/// flag path is unchanged. Windows are never put on screen.
@MainActor
struct WorkspacePinTilesTests {
    nonisolated static let session = "33333333-4444-4555-8666-777777777777"
    nonisolated static let keys = (1...3).map { WorkspaceKey(rawValue: "6c3e8d2f-9a4b-4f7c-8d1e-2b3c4d5e6f7\($0)") }

    nonisolated static func id(_ index: Int) -> String { keys[index - 1].rawValue }
    static func ref(_ index: Int) -> LayoutItemRef { .workspace("\(session):ws_\(index)") }

    /// w1..w3 with resource ids `ws_1..3` in session `session`; w2 carries
    /// the legacy pin flag. `owner` (served) or none (legacy).
    static func services(owner: SidebarLayoutServiceTests.FakeOwner?) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        if let owner {
            services.sidebarLayout = SidebarLayoutService(remote: owner, prototypeEnabled: { false },
                                                          recentsOffered: SidebarLayoutServiceTests.freshDefaults())
        }
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        tree(services)
        return services
    }

    /// Applies w1..w3 (`names`, `icons`) to the local store at `revision`.
    static func tree(_ services: AppServices, names: [String] = ["w1", "w2", "w3"], icons: [String?] = [nil, nil, nil], revision: UInt64 = 10) {
        let snapshots = keys.enumerated().map { index, key in
            let pane = PaneID(rawValue: UInt64(index + 1) * 10)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(index + 1) * 100), layout: .leaf(pane),
                                        panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)), title: "zsh")])])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: key, resourceID: ResourceID(rawValue: "ws_\(index + 1)"),
                                     name: names[index], screens: [screen], icon: icons[index], pinned: index == 1)
        }
        services.daemon.store.apply(snapshot: DaemonTree(registryID: session, workspaceRevision: revision, workspaces: snapshots))
    }

    private static func togglePin(_ services: AppServices, _ index: Int) -> ControlActionOutcome {
        ActionBindingCoverageTests.run(services, "palette.toggleWorkspacePin", target: ActionTargetRef(kind: .workspace, id: id(index)))
    }

    private static func rows(_ services: AppServices) -> [String] {
        let top = SidebarTopProjection.make(services.sidebarLayout, machines: services.machines, room: ProfileID.defaultProfile.rawValue)
        return SidebarBridge.sections(services.machines, members: keys.map(\.rawValue), profile: .defaultProfile, top: top)
            .flatMap(\.workspaces).map(\.id.rawValue)
    }

    /// Answers every update the owner holds, so no continuation leaks.
    private static func drain(_ owner: SidebarLayoutServiceTests.FakeOwner) async {
        for _ in 0..<500 {
            for call in owner.calls { owner.accept(call.key) }
            await Task.yield()
        }
    }

    @Test func refsAreQualifiedAndResolveBothWays() {
        let services = Self.services(owner: nil)
        let refs = WorkspaceLayoutRefs(machines: services.machines)
        #expect(refs.ref(forWorkspace: Self.id(1)) == Self.ref(1))
        #expect(refs.workspaceID(for: Self.ref(1)) == Self.id(1))
        #expect(refs.workspaceID(for: .workspace("other-session:ws_1")) == nil)
        #expect(refs.workspaceID(for: .workspace(Self.id(1))) == nil, "a bare id is not a layout ref")
    }

    @Test func pinWritesATileAndTheListLeavesTheRowOutUntilUnpin() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = Self.services(owner: owner)
        let before = Self.rows(services)
        #expect(before == [Self.id(1), Self.id(2), Self.id(3)], "the legacy flag draws no Pinned section once pins are tiles")
        #expect(Self.togglePin(services, 1) == .ran)
        let layout = services.sidebarLayout.document
        #expect(layout.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.ref) == [Self.ref(1)])
        #expect(Self.rows(services) == [Self.id(2), Self.id(3)])
        #expect(Self.togglePin(services, 1) == .ran)
        #expect(!services.sidebarLayout.document.isPinned(Self.ref(1)))
        #expect(Self.rows(services) == before, "unpin returns the row to its old place")
        await Self.drain(owner)
    }

    @Test func theMenuTitleFollowsTheTile() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = Self.services(owner: owner)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: Self.id(2)))
        let title = { services.registry.action(for: "palette.toggleWorkspacePin")?.targetTitle?(invocation) }
        #expect(title() == PinStrings.pinWorkspace, "the legacy flag is not the tile")
        #expect(Self.togglePin(services, 2) == .ran)
        #expect(title() == PinStrings.unpinWorkspace)
        await Self.drain(owner)
    }

    @Test func aTileDrawsItsWorkspaceAndAClosedOneIsDimmed() throws {
        let services = Self.services(owner: nil)
        let refs = WorkspaceLayoutRefs(machines: services.machines)
        var layout = SidebarLayoutDocument.defaults
        for ref in [Self.ref(3), .workspace("\(Self.session):ws_gone")] {
            layout = try SidebarLayoutReducer.reduce(layout, try #require(layout.pinOp(ref))).get()
        }
        let workspaces = SidebarWorkspaceItems.workspaceInfos(layout, refs: refs)
        let infos = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, workspace: { workspaces[$0] })
        let items = try #require(layout.section(SidebarLayoutDocument.pinnedSectionID)?.items)
        #expect(infos[items[0].id]?.title == "w3")
        #expect(infos[items[0].id]?.isMissing == false)
        #expect(infos[items[1].id]?.isMissing == true)
    }

    @Test func aTileKeepsItsWorkspaceNameForWhenItIsClosed() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = Self.services(owner: owner)
        #expect(Self.togglePin(services, 1) == .ran)
        let tile = try #require(services.sidebarLayout.document.section(SidebarLayoutDocument.pinnedSectionID)?.items.first)
        #expect(tile.label == "w1", "the name is stored with the pin")
        var layout = SidebarLayoutDocument.defaults
        layout = try SidebarLayoutReducer.reduce(layout, try #require(layout.pinOp(.workspace("\(Self.session):ws_gone"), label: "Old project"))).get()
        let closed = try #require(layout.section(SidebarLayoutDocument.pinnedSectionID)?.items.first)
        let info = SidebarBridge.itemInfo(for: layout, registered: { _ in true })[closed.id]
        #expect(info?.title == "Old project", "a closed workspace's tile shows its last known name, not its id")
        #expect(info?.isMissing == true)
        let stored = try JSONDecoder().decode(LayoutItem.self, from: JSONEncoder().encode(closed))
        #expect(stored.label == "Old project", "the label goes over the wire with the item")
        await Self.drain(owner)
    }

    @Test func aTileShowsTheLiveNameAndTheStoredNameOnlyWhenClosed() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = Self.services(owner: owner)
        #expect(Self.togglePin(services, 1) == .ran)
        Self.tree(services, names: ["Renamed", "w2", "w3"], revision: 11)
        let layout = services.sidebarLayout.document
        let tile = try #require(layout.section(SidebarLayoutDocument.pinnedSectionID)?.items.first)
        #expect(tile.label == "w1", "the stored name is from the pin")
        let workspaces = SidebarWorkspaceItems.workspaceInfos(layout, refs: WorkspaceLayoutRefs(machines: services.machines))
        let infos = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, workspace: { workspaces[$0] })
        #expect(infos[tile.id]?.title == "Renamed", "a rename shows on the tile at once")
        await Self.drain(owner)
    }

    @Test func anEmojiIconDrawsOnTheTile() throws {
        let services = Self.services(owner: nil)
        Self.tree(services, icons: ["🚀", nil, nil], revision: 11)
        let (workspace, _) = try #require(services.machines.workspace(id: Self.id(1)))
        #expect(SidebarWorkspaceItems.workspaceInfo(workspace).emoji == "🚀")
    }

    @Test func aTileDrawsTheGlyphItsRowStandsFor() throws {
        let services = Self.services(owner: nil)
        let (workspace, _) = try #require(services.machines.workspace(id: Self.id(1)))
        let info = SidebarWorkspaceItems.workspaceInfo(workspace)
        let row = SidebarMapping.shared.row(workspace, machine: .local)
        #expect(info.icon == row.kind.iconName, "a terminal workspace's tile draws the terminal glyph, as its row does")
        #expect(info.brand == row.kindBrand)
        #expect(info.title == "w1")
    }

    @Test func theSelectionMarksTheTileOfTheShownWorkspace() throws {
        let services = Self.services(owner: nil)
        let refs = WorkspaceLayoutRefs(machines: services.machines)
        var layout = SidebarLayoutDocument.defaults
        layout = try SidebarLayoutReducer.reduce(layout, try #require(layout.pinOp(Self.ref(2)))).get()
        let tile = try #require(layout.section(SidebarLayoutDocument.pinnedSectionID)?.items.first)
        #expect(SidebarNavigation.selectedItem(page: nil, workspace: Self.id(2), layout: layout, refs: refs) == .topItem(tile.id))
        #expect(SidebarNavigation.selectedItem(page: nil, workspace: Self.id(1), layout: layout, refs: refs)
            == .workspace(CmuxNextSidebar.WorkspaceID(Self.id(1))))
    }

    @Test func withoutTheOwnerPinsKeepTheLegacyPinnedSection() {
        let services = Self.services(owner: nil)
        let sections = SidebarBridge.sections(services.machines, members: Self.keys.map(\.rawValue), profile: .defaultProfile)
        #expect(sections.first?.id == .pinned)
        #expect(sections.first?.workspaces.map(\.id.rawValue) == [Self.id(2)])
    }
}

/// Add to Top (PINNED-ITEMS-END-TO-END P1): `sidebar.item.add` puts any
/// workspace (`workspace:<id>`, by sidebar, `ws_…` or qualified id) or app
/// (`app:<publisher>/<name>`) in the top rows; the tile menu names Remove
/// from Section by where the item is.
@MainActor
struct WorkspaceTopRowsTests {
    private static func add(_ services: AppServices, _ item: String) {
        _ = services.registry.perform("sidebar.item.add", invocation: ActionInvocation(arguments: ["item": .string(item)], origin: .cli))
    }

    @Test(arguments: [WorkspacePinTilesTests.id(1), "ws_1", "\(WorkspacePinTilesTests.session):ws_1"])
    func addToTopTakesAnyWorkspaceName(_ name: String) async {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        Self.add(services, "workspace:\(name)")
        let top = services.sidebarLayout.document.section(SidebarLayoutDocument.topSectionID)?.items.map(\.ref)
        #expect(top?.last == WorkspacePinTilesTests.ref(1))
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }

    @Test func addToTopTakesAnAppAndRefusesUnknownNames() async {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        Self.add(services, "app:acme/notes")
        Self.add(services, "workspace:ws_missing")
        Self.add(services, "app:bad")
        let top = services.sidebarLayout.document.section(SidebarLayoutDocument.topSectionID)?.items.map(\.ref)
        #expect(top?.suffix(1) == [.app("acme/notes")])
        #expect(top?.count == 3)
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }

    @Test func theWorkspaceRowMenuAddsToTopAndRemovesFromTop() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        let target = ActionTargetRef(kind: .workspace, id: WorkspacePinTilesTests.id(2))
        let title = { services.registry.action(for: "workspace.toggleTop")?.targetTitle?(ActionInvocation(target: target)) }
        let rowMenu = ContextMenuCatalog.shared.entries(for: .workspaceRow)
        #expect(ContextMenuCatalog.shared.referencedIDs(rowMenu).contains("workspace.toggleTop"), "the row menu offers Add to Top")
        #expect(title() == PinStrings.addToTop)
        #expect(ActionBindingCoverageTests.run(services, "workspace.toggleTop", target: target) == .ran)
        let row = try #require(services.sidebarLayout.document.section(SidebarLayoutDocument.topSectionID)?.items.last)
        #expect(row.ref == WorkspacePinTilesTests.ref(2))
        #expect(row.label == "w2")
        #expect(title() == PinStrings.removeFromTop)
        #expect(ActionBindingCoverageTests.run(services, "workspace.toggleTop", target: target) == .ran)
        #expect(!services.sidebarLayout.document.isOnTop(WorkspacePinTilesTests.ref(2)))
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }

    @Test func aRowDroppedOnTheTilesIsPinnedAtTheDropPoint() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        #expect(ActionBindingCoverageTests.run(services, "palette.toggleWorkspacePin",
                                               target: ActionTargetRef(kind: .workspace, id: WorkspacePinTilesTests.id(3))) == .ran)
        let commands = PinCommands(context: AppActionContext(services: services))
        try commands.dropWorkspaces([WorkspacePinTilesTests.id(1)], on: SidebarLayoutDocument.pinnedSectionID, at: 0, origin: .user)
        let tiles = { services.sidebarLayout.document.section(SidebarLayoutDocument.pinnedSectionID)?.items ?? [] }
        #expect(tiles().map(\.ref) == [WorkspacePinTilesTests.ref(1), WorkspacePinTilesTests.ref(3)], "the row lands where it was dropped")
        #expect(tiles().first?.label == "w1")
        try commands.dropWorkspaces([WorkspacePinTilesTests.id(1)], on: SidebarLayoutDocument.pinnedSectionID, at: 1, origin: .user)
        #expect(tiles().count == 2, "a workspace the section holds is not added twice")
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }

    @Test func removeFromSectionReadsAsUnpinOrRemoveFromTop() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        #expect(ActionBindingCoverageTests.run(services, "palette.toggleWorkspacePin",
                                               target: ActionTargetRef(kind: .workspace, id: WorkspacePinTilesTests.id(3))) == .ran)
        Self.add(services, "workspace:ws_1")
        let doc = services.sidebarLayout.document
        let tile = try #require(doc.section(SidebarLayoutDocument.pinnedSectionID)?.items.first)
        let row = try #require(doc.section(SidebarLayoutDocument.topSectionID)?.items.last)
        let title = { (id: LayoutItemID) in
            services.registry.action(for: "sidebar.item.remove")?.targetTitle?(ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: id.rawValue)))
        }
        #expect(title(tile.id) == PinStrings.unpinWorkspace)
        #expect(title(row.id) == PinStrings.removeFromTop)
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }
}

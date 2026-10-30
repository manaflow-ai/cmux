import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// `sidebar.numbering = workspacesOnly` (Settings > Keyboard > Command-Number Shortcuts > Workspaces Only):
/// Cmd-1 is the first workspace. The default sidebar draws Home and the App Store as a list row (the
/// document's top block), so they sit in `rows` and must still be skipped. The same holds for stepping.
@MainActor @Suite(.serialized)
struct SidebarNumberingWorkspacesOnlyTests {
    private static func model() throws -> (SidebarModel, [WorkspaceID]) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [1, 2, 3].map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        let machine = SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        let ids = try #require(machine.first?.workspaces.map(\.id))
        let block = CmuxNextSidebar.SidebarSection(
            kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue, title: "", showsTitle: false)), nodes: [])
        return (SidebarModel(sections: [block] + machine), ids)
    }

    @Test func commandOneIsTheFirstWorkspaceUnderTheTopBlock() throws {
        let (model, ids) = try Self.model()
        let order = model.itemOrder
        try #require(order.rows.first == .topItem(LayoutItemID("itm_home")), "the top block is not a list row: \(order.rows)")
        let settings = SidebarNavigationSettings(numbering: .workspacesOnly, cmd9: .last)
        #expect(order.pick(1, settings) == .workspace(ids[0]), "Cmd-1 picks \(String(describing: order.pick(1, settings)))")
        #expect(order.pick(3, settings) == .workspace(ids[2]))
        #expect(order.number(for: .topItem(LayoutItemID("itm_home")), settings) == nil, "Home still has a digit")
        #expect(order.number(for: .workspace(ids[0]), settings) == 1)
    }

    @Test func steppingWorkspacesOnlySkipsTheTopBlock() throws {
        let (model, ids) = try Self.model()
        let order = model.itemOrder
        let settings = SidebarNavigationSettings(stepping: .workspacesOnly)
        #expect(order.step(from: .workspace(ids[0]), by: -1, settings) == .workspace(ids[2]), "Previous from the first workspace lands on Home")
        #expect(order.step(from: nil, by: 1, settings) == .workspace(ids[0]))
    }

    @Test func everyItemStillCountsTheTopBlock() throws {
        let (model, _) = try Self.model()
        let settings = SidebarNavigationSettings(numbering: .allItems, cmd9: .last)
        #expect(model.itemOrder.pick(1, settings) == .topItem(LayoutItemID("itm_home")))
    }
}

import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// SIDEBAR-NUMBERING-AND-STEPPING + SIDEBAR-SELECTION-ONE-MODEL: one ordered
/// list of every visible sidebar item (top items, then the rows in shown
/// order; a collapsed group is one stop) drives Cmd-1…9 and Cmd-Ctrl-[ / ].
/// Defaults: Home = 1, App Store = 2, first workspace = 3, Cmd-9 = last,
/// stepping over every item, wrapping.
@MainActor
struct SidebarNavigationTests {
    static func ws(_ id: String, machine: MachineID = .local, state: SidebarRowState = .live) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: id, rowState: state)
    }

    static let cloud = MachineID("cloud")
    static let home = SidebarItem.topItem(LayoutItemID("itm_home"))
    static let store = SidebarItem.topItem(LayoutItemID("itm_app_store"))
    static func w(_ id: String) -> SidebarItem { .workspace(WorkspaceID(id)) }

    /// The default layout (Home, App Store on top), a pinned row, a machine
    /// section with a group between rows and a placeholder, a Cloud section.
    static func model(collapsedCloud: Bool = false, collapsedGroup: Bool = false) -> SidebarModel {
        SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(ws("p1"))]),
            SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: [
                .workspace(ws("w1")),
                .group(SidebarGroup(id: GroupID("g"), name: "g", isCollapsed: collapsedGroup, workspaces: [ws("w2"), ws("w3")])),
                .workspace(ws("w4", state: .placeholder)),
            ]),
            SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud)), isCollapsed: collapsedCloud,
                           nodes: [.workspace(ws("c1", machine: cloud))]),
        ])
    }

    @Test func theOrderIsTopItemsThenRowsInShownOrder() {
        #expect(Self.model().itemOrder.items == [Self.home, Self.store, Self.w("p1"), Self.w("w1"), Self.w("w2"), Self.w("w3"), Self.w("c1")])
    }

    /// A collapsed group is one stop; a collapsed section and filtered rows are none.
    @Test func hiddenRowsAreNotStopsAndACollapsedGroupIsOne() {
        let collapsed = Self.model(collapsedGroup: true).itemOrder
        #expect(collapsed.rows == [Self.w("p1"), Self.w("w1"), .group(GroupID("g")), Self.w("c1")])
        #expect(collapsed.stop(for: Self.w("w3")) == .group(GroupID("g")), "a member of a collapsed group stands at the group")
        #expect(Self.model(collapsedCloud: true).itemOrder.rows == [Self.w("p1"), Self.w("w1"), Self.w("w2"), Self.w("w3")])
        let filtered = Self.model()
        filtered.filterText = "w"
        #expect(filtered.itemOrder.rows == [Self.w("w1"), Self.w("w2"), Self.w("w3")])
    }

    /// Hidden and missing top items are not stops.
    @Test func hiddenTopItemsAreNotStops() {
        let model = Self.model()
        model.itemInfo[LayoutItemID("itm_app_store")] = SidebarItemInfo(title: "App Store", symbol: "bag", isHidden: true)
        #expect(model.itemOrder.topItems == [Self.home])
    }

    @Test func numberingDefaultsCountEveryItemAndNineIsLast() {
        let order = Self.model().itemOrder
        let settings = SidebarNavigationSettings()
        #expect(order.pick(1, settings) == Self.home)
        #expect(order.pick(2, settings) == Self.store)
        #expect(order.pick(3, settings) == Self.w("p1"), "the first workspace is Cmd-3")
        #expect(order.pick(9, settings) == Self.w("c1"))
        #expect(order.pick(8, settings) == Self.w("c1"), "past the end: the last")
        #expect(order.pick(0, settings) == nil)
    }

    @Test func workspacesOnlyNumberingAndNinth() {
        let order = Self.model().itemOrder
        var settings = SidebarNavigationSettings(numbering: .workspacesOnly)
        #expect(order.pick(1, settings) == Self.w("p1"), "classic: Cmd-1 is the first workspace")
        #expect(order.pick(9, settings) == Self.w("c1"))
        settings = SidebarNavigationSettings(cmd9: .ninth)
        #expect(order.pick(7, settings) == Self.w("c1"))
        #expect(order.pick(9, settings) == nil, "there is no ninth item")
    }

    /// Cmd-Ctrl-] from Home reaches the App Store, then the first workspace;
    /// Cmd-Ctrl-[ from the first workspace reaches the App Store; both wrap.
    @Test func steppingCrossesFromTopItemsIntoRowsAndWraps() {
        let order = Self.model().itemOrder
        let settings = SidebarNavigationSettings()
        #expect(order.step(from: Self.home, by: 1, settings) == Self.store)
        #expect(order.step(from: Self.store, by: 1, settings) == Self.w("p1"))
        #expect(order.step(from: Self.w("p1"), by: -1, settings) == Self.store)
        #expect(order.step(from: Self.w("c1"), by: 1, settings) == Self.home, "wraps at the end")
        #expect(order.step(from: Self.home, by: -1, settings) == Self.w("c1"), "wraps at the start")
    }

    @Test func steppingSettings() {
        let order = Self.model().itemOrder
        #expect(order.step(from: Self.w("c1"), by: 1, SidebarNavigationSettings(steppingWraps: false)) == nil)
        let rowsOnly = SidebarNavigationSettings(stepping: .workspacesOnly)
        #expect(order.step(from: Self.w("p1"), by: -1, rowsOnly) == Self.w("c1"), "top items are skipped and it wraps")
        #expect(order.step(from: Self.home, by: 1, rowsOnly) == Self.w("p1"), "from a top item: the first row")
    }

    /// Stepping onto a collapsed group stops at it, and from inside it moves on.
    @Test func aCollapsedGroupIsOneStep() {
        let order = Self.model(collapsedGroup: true).itemOrder
        let settings = SidebarNavigationSettings()
        #expect(order.step(from: Self.w("w1"), by: 1, settings) == .group(GroupID("g")))
        #expect(order.step(from: Self.w("w2"), by: 1, settings) == Self.w("c1"), "a selected member steps from the group")
    }

    /// The selection is one value: a page's top item clears the workspace.
    @Test func oneSelection() {
        let model = Self.model()
        model.activeWorkspaceID = WorkspaceID("w1")
        #expect(model.selectedItem == Self.w("w1"))
        model.selectedItem = Self.store
        #expect(model.activeWorkspaceID == nil)
    }
}

import AppKit
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// R52 (Lawrence 2026-10-03): no window rail. The sidebar sits flush on the
/// window's leading edge and its sections hold the destinations again:
/// Home, the App Store and CodeRouter on top, Settings and the account at
/// the bottom (plans/cmux-next/sidebar-sections.md). Before, a rail at the
/// leading edge held them and the sidebar started with the workspace list.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct SectionsSidebarDefaultTests {
    /// FIRST-PARTY-APPS (Lawrence 2026-10-04): CodeRouter is not in the
    /// top-left area by default; the palette and the App Store reach it, and
    /// a user who shows it again gets an ordinary item.
    @Test func theDefaultLayoutIsTheSectionsSidebar() {
        let top = SidebarLayoutDocument.defaults.sections(in: .top, room: nil).flatMap(\.items).map(\.id.rawValue)
        let bottom = SidebarLayoutDocument.defaults.sections(in: .bottom, room: nil).flatMap(\.items).map(\.id.rawValue)
        #expect(top == ["itm_home", "itm_app_store"])
        // Lawrence 2026-10-05: the top is plain rows, not a tiles card.
        #expect(SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.topSectionID)?.arrangement == .list)
        let shown = SidebarLayoutReducer.reduce(.defaults, .itemAdd(LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter")),
                                                                     section: SidebarLayoutDocument.topSectionID, index: 99))
        #expect((try? shown.get())?.sections(in: .top, room: nil).flatMap(\.items).map(\.id.rawValue) == ["itm_home", "itm_app_store", "itm_app_coderouter"])
        // SIDEBAR-FOOTER-MINIMAL: the footer is the avatar, then the gear.
        #expect(bottom == ["itm_account", "itm_settings"])
    }

    @Test func aWindowShowsTheSectionsInTheSidebarAtTheLeadingEdge() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let sidebar = harness.window.sidebar.container
        sidebar.window?.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        sidebar.window?.contentView?.layoutSubtreeIfNeeded()
        let view = sidebar.sidebarView
        #expect(sidebar.convert(sidebar.bounds, to: nil).minX == 0, "the sidebar is flush on the leading edge (no rail)")
        #expect(view.aboveRegion.itemView(LayoutItemID("itm_app_coderouter")) == nil, "CodeRouter is not in the top band by default")
        for id in ["itm_home", "itm_app_store"] {
            #expect(view.aboveRegion.itemView(LayoutItemID(id))?.style == .builtIn, "\(id) is a plain row in the top band")
        }
        for id in ["itm_new_workspace", "itm_import_sync"] {
            #expect(view.aboveRegion.itemView(LayoutItemID(id)) == nil, "\(id) is not in the top band by default")
        }
        #expect(view.belowRegion.itemView(LayoutItemID("itm_settings")) != nil)
        #expect(view.belowRegion.itemView(LayoutItemID("itm_account")) != nil)
    }

    /// A layout the rail default migrated is moved back by ordinary layout
    /// ops; a layout the user changed is left alone.
    @Test func aRailDefaultLayoutMovesBackToTheSections() {
        #expect(Self.railDefaults.layoutMigration.sections == Self.migratedRail)
        var custom = Self.railDefaults
        custom.sections[0].items.removeLast()
        // Customized: only its built-in Home and App Store become app items.
        #expect(custom.sectionsMigrationOps.isEmpty)
        #expect(custom.layoutMigrationOps == custom.appRefMigrationOps)
        #expect(SidebarLayoutDocument.defaults.layoutMigrationOps.isEmpty)
    }

    static var migratedRail: [LayoutSection] { SidebarLayoutDocument.migrationTarget.sections }

    /// The rail default layout as stored (Leo, 2026-10-03, #17153).
    static let railDefaults = SidebarLayoutDocument(sections: [
        LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, maxRows: 4,
                      items: [LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home)),
                              LayoutItem(id: LayoutItemID("itm_app_store"), ref: .builtIn(.appStore)),
                              LayoutItem(id: LayoutItemID("itm_history"), ref: .builtIn(.history)),
                              LayoutItem(id: LayoutItemID("itm_notifications"), ref: .builtIn(.notifications)),
                              LayoutItem(id: LayoutItemID("itm_settings"), ref: .builtIn(.settings)),
                              LayoutItem(id: LayoutItemID("itm_customize"), ref: .builtIn(.customize)),
                              LayoutItem(id: LayoutItemID("itm_app_coderouter"), ref: .app("cmux/coderouter"))]),
        LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, look: .list, content: .workspaces),
        LayoutSection(id: SidebarLayoutDocument.bottomSectionID, region: .bottom, look: .builtIn,
                      arrangement: SectionArrangement(layout: .inline, align: .fill), items: [
                          LayoutItem(id: LayoutItemID("itm_account"), ref: .builtIn(.account), showsLabel: false),
                      ]),
    ])
}

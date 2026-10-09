import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSidebar

/// DOGFOOD-CALL-2026-10-06 S1: workspace rows are minimal by default (no
/// folder line), the group header's caret is on the left, and the old
/// New / Import and Sync sidebar items are gone, also from stored layouts.
@MainActor @Suite struct MinimalSidebarS1Tests {
    // MARK: Folder line

    @Test func aWorkspaceRowShowsNoFolderLineByDefault() throws {
        let ws = SidebarWorkspace(id: id("a"), title: "a", directory: "~/src/app")
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(ws)])]
        let m = SidebarLayoutMetrics.standard
        let row = try #require(SidebarLayout.make(sections: sections, metrics: m).rows.first)
        #expect(row.height == m.rowHeight, "the folder line is off by default")
    }

    @Test func aWorkspaceRowViewDrawsNoFolderTextByDefault() throws {
        let h = MinimalChromeTests.Harness(sections: fixture())
        let row = try #require(h.sidebar.list.rowViews[.workspace(id("a"))] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let texts = row.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        #expect(!texts.contains("sub-a"), "visible texts: \(texts)")
    }

    /// SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE supersedes "a live status always
    /// shows": the agent status line is its own element, off by default.
    @Test func theSettingTurnsTheFolderLineOnAndTheStatusIsItsOwnElement() throws {
        let passive = SidebarWorkspace(id: id("a"), title: "a", directory: "~/src/app")
        let live = SidebarWorkspace(id: id("b"), title: "b", directory: "~/src/app", status: "Claude: running tests")
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                       nodes: [.workspace(passive), .workspace(live)])]
        let m = SidebarLayoutMetrics.standard
        let off = SidebarLayout.make(sections: sections, metrics: m).rows
        #expect(off.map(\.detail) == [nil, nil])
        var o = SidebarLayoutOptions()
        o.workspaceRow.base.shown.insert(.directory)
        let on = SidebarLayout.make(sections: sections, metrics: m, options: o).rows
        #expect(on.map(\.detail) == ["~/src/app", "~/src/app"])
        #expect(on.allSatisfy { $0.height == m.rowHeightWithSubtitle })
    }

    @Test func theModelPassesTheSettingToTheList() {
        let model = SidebarModel(sections: fixture())
        var preferences = SidebarSectionsPreferences.defaults
        preferences.workspaceRow.base.shown.insert(.directory)
        model.applyListPreferences(preferences)
        #expect(model.listOptions().workspaceRow.base.shows(.directory))
    }

    // MARK: Group caret

    /// cx-rcby: the chevron ends the group chip, after the name, like the
    /// Chrome tab group chip, and shows without hover.
    @Test func theGroupChevronEndsTheChipAndShowsAtRest() throws {
        let h = MinimalChromeTests.Harness(sections: fixture())
        let header = try #require(h.sidebar.list.rowViews[.group(g1)] as? GroupHeaderRowView)
        header.isHovered = false
        header.layoutSubtreeIfNeeded()
        #expect(header.disclosureFrame.midX > header.titleFrame.maxX, "chevron \(header.disclosureFrame) name \(header.titleFrame)")
        #expect(header.labelFrame.contains(NSPoint(x: header.disclosureFrame.midX, y: header.disclosureFrame.midY)), "inside the chip")
        let chevron = header.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.frame.minX >= header.titleFrame.maxX }
        #expect(chevron != nil, "the chevron shows on an expanded group without hover")
    }

    // MARK: Retired items

    @Test func newWorkspaceAndImportSyncAreNoLongerSidebarItems() {
        #expect(SidebarBuiltIn(rawValue: "new_workspace") == nil)
        #expect(SidebarBuiltIn(rawValue: "import_sync") == nil)
    }

    @Test func aStoredLayoutDropsTheRetiredItemsAndKeepsTheRest() throws {
        let retired = [LayoutItemRef(kind: LayoutItemRef.builtInKind, value: "new_workspace"),
                       LayoutItemRef(kind: LayoutItemRef.builtInKind, value: "import_sync")]
        var stored = SidebarLayoutDocument.defaults
        stored.sections[0].arrangement = SidebarLayoutDocument.tilesArrangement
        stored.sections[0].items += [LayoutItem(id: LayoutItemID("itm_new_workspace"), ref: retired[0]),
                                     LayoutItem(id: LayoutItemID("itm_import_sync"), ref: retired[1])]
        // A retired item the user moved into another section goes too.
        let bottom = try #require(stored.sections.firstIndex { $0.id == SidebarLayoutDocument.bottomSectionID })
        stored.sections[bottom].items.append(LayoutItem(id: LayoutItemID("itm_new_2"), ref: retired[0]))
        let migrated = stored.layoutMigration
        let refs = migrated.sections.flatMap(\.items).map(\.ref)
        #expect(!refs.contains(retired[0]) && !refs.contains(retired[1]))
        #expect(migrated.sections[0].items.map(\.id) == [LayoutItemID("itm_home"), LayoutItemID("itm_app_store")])
        #expect(migrated.sections[0].arrangement == SidebarLayoutDocument.tilesArrangement, "the user's arrangement stays")
        #expect(migrated.layoutMigrationOps.isEmpty, "the migration runs once")
    }
}

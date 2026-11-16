// Proof copy for #43516 (c4401c9e): the class test with the allowlist as it would read there (no sharing badge yet).
import AppKit
@testable import CmuxNextSidebar
import Testing

/// The class guard for row chrome at rest (Leo 2026-11-16, on the share arrow drawn on every sidebar row: "Holy moly is
/// THIS the icon for screen sharing???", then "WHAT THE HELL KIND OF BONEHEADED DECISION WAS THAT"). No sidebar row
/// draws an action at rest: a row's buttons show on hover, on the selected row, or while their menu is open. Every
/// mounted row is walked with no pointer and no selection, and any interactive subview it draws fails the test, so a
/// control a future change adds to a row's `interactiveSubviews` is caught here before it reaches a nightly. The only
/// exceptions are marks that show state rather than offer an action, listed in `stateMarks` with their reason.
@MainActor @Suite(.serialized) struct SidebarRowControlsAtRestTests {
    /// Controls allowed at rest, each because it shows state, not an action, or because a settled design keeps it.
    static func stateMarks(_ row: SidebarRowView) -> [NSView] {
        switch row {
        case let row as WorkspaceRowView:
            // The speaker shows the tabs play or are muted; the drive indicator shows an agent driving; a folded parent's
            // chevron shows it is folded (an open one is hover or selection only, design/sidebar.md); the sharing badge
            // shows This Mac sharing on the row on screen.
            [row.audioSlot.made, row.driveIndicator, row.treeFold == .collapsed ? row.treeFoldSlot.made : nil].compactMap(\.self)
        case let row as SectionHeaderRowView:
            // A machine header's + stays at rest (cx-g2kk, #19023: hiding it made the sidebar's bottom flash); its
            // sharing badge shows This Mac sharing.
            [row.addButton]
        case is ListHeaderRowView:
            []
        case let row as EmptyGroupRowView:
            // An empty group's row is its + (nothing else to draw).
            [row.addButton]
        default:
            []
        }
    }

    static func drawn(_ view: NSView) -> Bool { !view.isHidden && view.alphaValue > 0 && view.superview != nil }

    @Test(arguments: [false, true])
    func noRowDrawsAnActionAtRest(grouped: Bool) throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: SidebarScreenActionTests.examples)
        model.groupsByComputer = grouped
        let list = SidebarListView(model: model)
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let rows = Array(list.rowViews.values)
        #expect(rows.count >= SidebarScreenActionTests.examples.count, "the fixture mounts every row")
        var offenders: [String] = []
        for row in rows {
            #expect(!row.isHovered && !row.isSelected)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let allowed = Self.stateMarks(row)
            for control in row.interactiveSubviews where Self.drawn(control) && !allowed.contains(where: { $0 === control }) {
                offenders.append("\(type(of: row)) \(row.key): \(type(of: control)) \(control.accessibilityIdentifier())")
            }
        }
        #expect(offenders.isEmpty, "row actions drawn at rest: \(offenders)")
    }

    /// The guard has teeth: the same walk finds the controls a hovered row draws.
    @Test func theWalkSeesHoverControls() throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: SidebarScreenActionTests.examples)
        model.groupsByComputer = false
        let list = SidebarListView(model: model)
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 1000)
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let row = try #require(list.rowViews[.workspace(WorkspaceID("ws-cloud"))] as? WorkspaceRowView)
        row.isHovered = true
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let marks = Self.stateMarks(row)
        let shown = row.interactiveSubviews.filter { control in Self.drawn(control) && !marks.contains { $0 === control } }
        #expect(shown.contains { $0 === row.screenSlot.made }, "View screen draws on hover")
        #expect(shown.contains { $0 === row.moreSlot.made }, "the menu button draws on hover")
    }
}

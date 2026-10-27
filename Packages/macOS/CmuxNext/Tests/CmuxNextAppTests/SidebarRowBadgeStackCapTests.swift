import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-14 on the glyph stack (`sidebar.rowBadge` stack): it shows up to five items, not
/// three, and Debug Settings picks 3, 5 or 7 (`sidebar.rowBadgeStack`); the rest read in the
/// tooltip and hover card. Debug Settings also lists a preview set (`sidebar.rowBadgePreview`):
/// rows with 1 to 7 pending items, without real sessions, that nothing can select.
@MainActor @Suite(.serialized) struct SidebarRowBadgeStackCapTests {
    private static let busy = WorkspaceID("ws-busy")

    private static func sidebar(_ sections: [SidebarSection], style: SidebarRowBadgeStyle = .stack) -> SidebarView {
        let model = SidebarModel(sections: sections)
        model.rowBadgeStyle = style
        // The stack lists each state apart only with detailed status icons (`sidebar.detailedStatusIcons`).
        model.detailedStatus = true
        let design = DesignSettings()
        design.sidebarSections.detailedStatusIcons = true
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    /// A row with seven pending items: a failure and six unread.
    private static func sevenItems(style: SidebarRowBadgeStyle = .stack) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let row = SidebarWorkspace(id: busy, title: "api", kind: .terminal, unread: .count(6), activity: .error)
        return sidebar([SidebarSection(kind: .machine(machine), nodes: [.workspace(row)])], style: style)
    }

    private static func stack(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> RowBadgeView {
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        return row.rowBadge
    }

    /// Runs `body` with the stack cap set to `cap` (nil: the default), then clears it. The store is
    /// active without a file, so nothing is written. Each set is followed by a drop of the tunables
    /// watch's kept values, which the app's sidebar look watch does in the next frame: the rows `body`
    /// draws in this same turn would otherwise read the values cached for a row another suite drew earlier.
    private static func withCap(_ cap: SidebarRowBadgeStackCap?, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarRowBadgeStackCap.tunable.key
        if let cap {
            try #require(TunableStore.shared.set(key, cap.tunableValue) == cap.tunableValue, "the stack size takes the override")
        } else {
            TunableStore.shared.set(key, nil)
        }
        SidebarTunablesWatch.shared.drop()
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.drop()
        }
        try body()
    }

    @Test func theStackShowsFiveItemsByDefaultAndTheRestReadInTheTooltip() throws {
        try Self.withCap(nil) {
            let stack = try Self.stack(Self.sevenItems(), Self.busy)
            #expect(stack.states.count == 5)
            #expect(stack.states.first == .error, "the most urgent first")
            #expect(stack.themedToolTip?.contains(Strings.statusMore(2)) == true)
        }
    }

    /// cx-az6hc: in a whole-process run another suite draws a sidebar row first, so the shared
    /// tunables watch already holds the default cap when a test sets its own. The cap still
    /// applies to the next row drawn.
    @Test func aCapSetAfterAnotherRowDrewAppliesToTheNextRow() throws {
        try Self.withCap(nil) { _ = Self.sevenItems() }
        try Self.withCap(.three) {
            let stack = try Self.stack(Self.sevenItems(), Self.busy)
            #expect(stack.states.count == 3)
        }
    }

    @Test func theCornerBadgeTooltipListsEveryStateWithoutAMoreCount() throws {
        try Self.withCap(.three) {
            let corner = try Self.stack(Self.sevenItems(style: .corner), Self.busy)
            #expect(corner.states.count == 1)
            #expect(corner.themedToolTip?.contains(Strings.unreadCount(6)) == true)
            #expect(corner.themedToolTip?.contains(Strings.statusMore(4)) == false)
        }
    }

    @Test(arguments: [(SidebarRowBadgeStackCap.three, 3), (.five, 5), (.seven, 7)])
    func debugSettingsPicksTheCap(_ cap: SidebarRowBadgeStackCap, _ shown: Int) throws {
        try Self.withCap(cap) {
            let stack = try Self.stack(Self.sevenItems(), Self.busy)
            #expect(stack.states.count == shown)
            let more = 7 - shown
            #expect((stack.themedToolTip?.contains(Strings.statusMore(more)) == true) == (more > 0))
        }
    }

    @Test func thePreviewSetShowsOneToSevenItemsAndNothingSelectsThem() throws {
        try Self.withCap(.seven) {
            let sections = SidebarSection.rowBadgePreview()
            let rows = sections.flatMap(\.workspaces)
            #expect(rows.count == 7)
            let sidebar = Self.sidebar(sections)
            for (index, row) in rows.enumerated() {
                let shown = try Self.stack(sidebar, row.id).states.count
                #expect(shown == index + 1, "row \(index + 1)")
                #expect(sidebar.list.model.isPlaceholder(row.id), "a preview row is never selected or opened")
                #expect(!row.isClosable, "a preview row has no close button")
            }
        }
    }
}

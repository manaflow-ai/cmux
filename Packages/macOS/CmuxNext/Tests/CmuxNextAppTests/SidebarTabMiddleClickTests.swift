import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPalette
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-27, on a workspace's listed tabs in the sidebar: "we need to be able to middle-click and, you know,
/// just deal with the stuff here. Like just closing tabs fundamentally." A middle-click closes exactly the tab under
/// it wherever a tab is listed: a sidebar tab row (`.closeTab`, which the App runs as Close Tab), and a Search Tabs
/// row (its Cmd-W close). The tab strip's own middle-click is unchanged. A workspace row keeps closing its workspace.
@MainActor @Suite(.serialized)
struct SidebarTabMiddleClickTests {
    typealias Fixture = SidebarTabGroupControlsTests
    typealias Gallery = SidebarTabMiddleClickGalleryTests

    /// The sidebar fixture with every intent it sends recorded instead of applied.
    static func recording() -> (SidebarListView, NSWindow, () -> [SidebarIntent]) {
        let (model, sidebar, window) = Fixture.sidebar()
        window.orderFrontRegardless()
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        return (sidebar.list, window, { sent })
    }

    @Test func aMiddleClickOnATabRowClosesExactlyThatTab() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        try Gallery.middleClick(list, .tab(Fixture.shown, Fixture.second))
        #expect(sent() == [.closeTab(workspace: Fixture.shown, tab: Fixture.second)])
    }

    /// A tab of a workspace that is not shown closes too, and the shown workspace stays as it is.
    @Test func aTabOfAnotherWorkspaceClosesWithoutSwitching() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        let tab = CmuxNextSidebar.TabID("tg-tab-4")
        try Gallery.middleClick(list, .tab(Fixture.other, tab))
        #expect(sent() == [.closeTab(workspace: Fixture.other, tab: tab)])
        #expect(list.model.activeWorkspaceID == Fixture.shown)
    }

    /// A press on one tab released on another closes nothing, as on the tab strip.
    @Test func aReleaseOnAnotherRowClosesNothing() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        try Gallery.middleClick(list, .tab(Fixture.shown, Fixture.first), releasedOn: .tab(Fixture.shown, Fixture.second))
        try Gallery.middleClick(list, .tab(Fixture.shown, Fixture.first), releasedOn: .workspace(Fixture.shown))
        #expect(sent().isEmpty)
    }

    /// The workspace row keeps its own middle-click: its workspace closes (MIDDLE-CLICK-CLOSES-WORKSPACE).
    @Test func aMiddleClickOnAWorkspaceRowStillClosesTheWorkspace() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        try Gallery.middleClick(list, .workspace(Fixture.other))
        #expect(sent() == [.close([Fixture.other])])
    }

    /// Leo 2026-10-28: "when you're hovering over that, I think it also wants the close button on there as well."
    /// A hovered tab row shows the workspace row's ✕ (one button, `SidebarRowCloseButton`) on the trailing column,
    /// where the tab's status gives way; its press closes the tab as the middle-click does; the hover's end hides it.
    @Test func aHoveredTabRowShowsTheCloseAtItsEnd() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        let row = try Fixture.tabRow(list, Fixture.shown, Fixture.first)
        row.layoutSubtreeIfNeeded()
        #expect(row.closeButton.isHidden, "a tab row at rest shows a ✕")
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        #expect(!row.closeButton.isHidden && row.closeButton.alphaValue == 1, "a hovered tab row shows no ✕")
        let b = row.layoutBounds
        #expect(row.closeButton.frame == SidebarStyle.rowCloseFrame(rowWidth: b.width, centerY: b.height / 2))
        // The row hands a click there to the ✕ alone; the rest of the row stays the list's.
        let center = NSPoint(x: row.closeButton.frame.midX, y: row.closeButton.frame.midY)
        #expect(row.hitTest(row.convert(center, to: row.superview)) === row.closeButton)
        #expect(row.hitTest(row.convert(NSPoint(x: b.midX / 2, y: b.midY), to: row.superview)) == nil)
        // The same ✕ as a workspace row's (both from `SidebarIconButton.rowClose`).
        let workspace = try #require(list.rowViews[.workspace(Fixture.shown)] as? WorkspaceRowView)
        #expect(workspace.closeButton.icon == row.closeButton.icon)
        // A middle-click on the ✕ itself is the row's: it reaches the list and closes the tab.
        let onClose = row.convert(center, to: list)
        row.closeButton.otherMouseDown(with: try Gallery.middle(.otherMouseDown, at: onClose, in: list))
        row.closeButton.otherMouseUp(with: try Gallery.middle(.otherMouseUp, at: onClose, in: list))
        #expect(sent() == [.closeTab(workspace: Fixture.shown, tab: Fixture.first)])
        row.closeButton.onPress?()
        #expect(sent() == [.closeTab(workspace: Fixture.shown, tab: Fixture.first), .closeTab(workspace: Fixture.shown, tab: Fixture.first)])
        row.isHovered = false
        row.layoutSubtreeIfNeeded()
        #expect(row.closeButton.isHidden, "the ✕ stayed after the hover ended")
    }

    /// With #26622's column: a tab row's unread dot alone sits on the trailing column; on hover the ✕ takes it and
    /// the dot gives way at once, never both; leaving hides the ✕ and the dot is back. A dot beside a status stays
    /// left of the column, where the status gave way to the ✕.
    @Test func theCloseTakesTheColumnFromTheTabsMark() throws {
        let workspace = Fixture.shown, section = SectionID.machine(.local)
        for working in [false, true] {
            let tab = SidebarTrailingColumnTests.tab(TabID("tab-mark"), "zsh", unread: true, working: working)
            let key = SidebarRowKey.tab(workspace, tab.id)
            let view = SidebarTabRowView(key: key)
            view.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
            view.configure(tab, row: SidebarRow(key: key, y: 0, height: 28, section: section, workspace: workspace, siblingIndex: 0,
                                                isLastInGroup: true, isCollapsed: false, childCount: 1))
            view.onClose = {}
            view.layoutSubtreeIfNeeded()
            let column = SidebarStyle.rowCloseFrame(rowWidth: 260, centerY: 14)
            let dot = try #require(view.subviews.first { $0 is UnreadBadgeView })
            #expect(dot.frame.midX == column.midX || working, "a lone dot is off the column")
            view.isHovered = true
            view.layoutSubtreeIfNeeded()
            #expect(!view.closeButton.isHidden && view.closeButton.frame == column)
            let onColumn = view.subviews.filter { $0 !== view.closeButton && !$0.isHidden && $0.alphaValue > 0 && $0.frame.intersects(column) }
            #expect(onColumn.isEmpty, "the ✕ shares the column with \(onColumn)")
            #expect(dot.alphaValue == (working ? 1 : 0))
            view.isHovered = false
            view.layoutSubtreeIfNeeded()
            #expect(view.closeButton.isHidden && dot.alphaValue == 1, "leaving left the ✕ up or the dot down")
        }
    }

    // MARK: - Search Tabs rows

    private final class ThreeRows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    /// A palette row's middle press and release on the same row report it; across rows, or another button, nothing.
    @Test func aPaletteRowReportsAMiddleClickOnTheSameRow() throws {
        _ = NSApplication.shared
        let rows = ThreeRows()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = PaletteTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 90))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.dataSource = rows
        window.contentView = table
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, row: Int, button: Int64 = 2) throws -> NSEvent {
            try Self.middle(type, row: row, in: table, window: window, button: button)
        }
        var clicked: [Int] = []
        table.onMiddleClick = { clicked.append($0) }
        table.otherMouseDown(with: try event(.otherMouseDown, row: 1))
        table.otherMouseUp(with: try event(.otherMouseUp, row: 1))
        #expect(clicked == [1])
        table.otherMouseDown(with: try event(.otherMouseDown, row: 0))
        table.otherMouseUp(with: try event(.otherMouseUp, row: 2))
        table.otherMouseDown(with: try event(.otherMouseDown, row: 2, button: 3))
        table.otherMouseUp(with: try event(.otherMouseUp, row: 2, button: 3))
        #expect(clicked == [1])
    }

    /// A middle-button event (button `button`, 2 by default) at the center of `table`'s row `row`.
    static func middle(_ type: NSEvent.EventType, row: Int, in table: NSTableView, window: NSWindow, button: Int64 = 2) throws -> NSEvent {
        let rect = table.rect(ofRow: row)
        let base = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        let made = try #require(DebugMouse.mouse(type, at: NSPoint(x: base.x, y: height - base.y), in: window, flags: [], clicks: 1))
        guard button != 2, let cg = made.cgEvent?.copy() else { return made }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return try #require(DebugMouse.keepingWindowPoint(cg, made.locationInWindow))
    }

    /// The press holds its row's tab: when a search lands between press and release and another tab takes that
    /// place, the release closes nothing; the next middle-click on the row closes the tab now there.
    @Test func aPaletteReleaseAfterTheRowsChangedClosesNothing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = PaletteListView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = list
        func sections(_ ids: [String]) -> [PaletteResultSection] {
            let open = PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {})
            return [PaletteResultSection(section: .results, rows: ids.map { PaletteRow(item: PaletteItem(id: $0, title: $0, primary: open), highlights: [], score: 0) })]
        }
        list.setSections(sections(["tab:a", "tab:b"]))
        list.layoutSubtreeIfNeeded()
        let table = try #require(list.documentView as? PaletteTableView)
        let row = table.numberOfRows - 2 // "tab:a", after the section's title row if it has one
        var closed: [String] = []
        list.onMiddleClick = { closed.append($0) }
        table.otherMouseDown(with: try Self.middle(.otherMouseDown, row: row, in: table, window: window))
        list.setSections(sections(["tab:b", "tab:a"]))
        table.otherMouseUp(with: try Self.middle(.otherMouseUp, row: row, in: table, window: window))
        #expect(closed.isEmpty, "the release closed the tab that took the pressed row's place")
        table.otherMouseDown(with: try Self.middle(.otherMouseDown, row: row, in: table, window: window))
        table.otherMouseUp(with: try Self.middle(.otherMouseUp, row: row, in: table, window: window))
        #expect(closed == ["tab:b"])
    }

    /// A middle-click on a Search Tabs row, through the shown palette (its content view, list and table), closes that
    /// row's tab, as Cmd-W on it does; the selection stays where it was.
    @Test func aMiddleClickOnASearchTabsRowClosesItsTab() async throws {
        _ = NSApplication.shared
        let source = MockTabSearchSource()
        let model = PaletteModel(usage: LocalPaletteUsageStore(persistence: nil))
        let content = PaletteContentView(model: model)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = content
        window.orderFrontRegardless()
        model.reset(to: .tabSearch(source: source)) // as the palette opens it (`PaletteController.show(page:)`)
        let table = try #require(AANestedGroupsGalleryTests.all(content).lazy.compactMap { $0 as? PaletteTableView }.first)
        // The rows as the list lays them out: each section's title row (if it has one), then its rows.
        func displayed() -> [String?] {
            model.sections.flatMap { section in (section.title.isEmpty ? [] : [nil]) + section.rows.map { Optional($0.id) } }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.searchTask != nil || model.rows.filter({ $0.id.hasPrefix("tab:") && $0.item.isEnabled }).count < 2
                || table.numberOfRows != displayed().count, ContinuousClock.now < deadline {
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        content.layoutSubtreeIfNeeded()
        let rows = displayed()
        try #require(!rows.isEmpty, "Search Tabs listed nothing")
        try #require(table.numberOfRows == rows.count, "the list shows \(table.numberOfRows) rows of \(rows.count)")
        let selected = model.selectedRowID
        let enabled = Set(model.rows.filter { $0.item.isEnabled }.map(\.id))
        let index = try #require(rows.indices.first { i in
            guard let id = rows[i], id.hasPrefix("tab:"), id != selected, enabled.contains(id) else { return false }
            return table.visibleRect.contains(NSPoint(x: table.rect(ofRow: i).midX, y: table.rect(ofRow: i).midY))
        }, "no visible open tab row besides the selected one: \(rows)")
        let target = try #require(rows[index])
        table.otherMouseDown(with: try Self.middle(.otherMouseDown, row: index, in: table, window: window))
        table.otherMouseUp(with: try Self.middle(.otherMouseUp, row: index, in: table, window: window))
        #expect(source.closed == [String(target.dropFirst("tab:".count))])
        #expect(model.selectedRowID == selected)
    }
}

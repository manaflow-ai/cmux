import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPalette
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-27: "we need to be able to middle-click and, you know, just deal with the stuff here. Like just closing
/// tabs fundamentally." A middle-click on a Search Tabs row closes exactly that row's tab (its Cmd-W close). The tab
/// strip's own middle-click is unchanged. A sidebar workspace row closes its workspace.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarTabMiddleClickTests {
    typealias Fixture = SidebarRowCloseSpotTests

    /// The sidebar fixture with every intent it sends recorded instead of applied.
    static func recording() -> (SidebarListView, NSWindow, () -> [SidebarIntent]) {
        let (model, sidebar, window) = Fixture.sidebar()
        window.orderFrontRegardless()
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        return (sidebar.list, window, { sent })
    }

    /// The workspace row keeps its own middle-click: its workspace closes (MIDDLE-CLICK-CLOSES-WORKSPACE).
    @Test func aMiddleClickOnAWorkspaceRowStillClosesTheWorkspace() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        try Self.middleClick(list, .workspace(Fixture.other))
        #expect(sent() == [.close([Fixture.other])])
    }

    /// A middle-button event (button number 2, as a real one) at `point` in `list`, through DebugMouse's mapping.
    static func middle(_ type: NSEvent.EventType, at point: NSPoint, in list: SidebarListView) throws -> NSEvent {
        let window = try #require(list.window)
        let base = list.convert(point, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        let event = try #require(DebugMouse.mouse(type, at: NSPoint(x: base.x, y: height - base.y), in: window, flags: [], clicks: 1))
        #expect(event.buttonNumber == 2)
        return event
    }

    /// A middle press on `down`'s row and its release on `up`'s (the same row by default).
    static func middleClick(_ list: SidebarListView, _ down: SidebarRowKey, releasedOn up: SidebarRowKey? = nil) throws {
        let pressed = try SidebarIncrementalMatchesRebuildGapsTests.center(list, down)
        let released = try SidebarIncrementalMatchesRebuildGapsTests.center(list, up ?? down)
        list.otherMouseDown(with: try middle(.otherMouseDown, at: pressed, in: list))
        list.otherMouseUp(with: try middle(.otherMouseUp, at: released, in: list))
    }

    /// A press on one workspace row released on another closes nothing.
    @Test func aReleaseOnAnotherRowClosesNothing() throws {
        let (list, window, sent) = Self.recording()
        defer { window.close() }
        try Self.middleClick(list, .workspace(Fixture.shown), releasedOn: .workspace(Fixture.other))
        #expect(sent().isEmpty)
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

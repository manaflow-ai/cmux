import AppKit
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19: "mouse down to immediately open", Cmd+P rows included. A press on a
/// visible row runs it at once; the drag and release that follow run nothing more. A press off
/// every visible row runs nothing.
@MainActor
@Suite(.closesItsWindows)
struct PalettePressTests {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    private let rows = Rows()

    private func table() -> (NSWindow, PaletteTableView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 90), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let table = PaletteTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 90))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.dataSource = rows
        window.contentView = table
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        return (window, table)
    }

    /// A mouse event at the vertical center of `row`, in window coordinates.
    private func event(_ type: NSEvent.EventType, row: Int, in table: PaletteTableView, window: NSWindow) -> NSEvent {
        let rect = row >= 0 ? table.rect(ofRow: row) : NSRect(x: 0, y: -40, width: 200, height: 1)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @Test func pressRunsTheRowUnderThePointerAtOnce() {
        let (window, table) = table()
        defer { window.closeAfterTest() }
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        table.mouseDown(with: event(.leftMouseDown, row: 1, in: table, window: window))
        #expect(ran == [1])
    }

    @Test func dragAndReleaseAfterThePressRunNothingMore() {
        let (window, table) = table()
        defer { window.closeAfterTest() }
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        table.mouseDown(with: event(.leftMouseDown, row: 0, in: table, window: window))
        table.mouseDragged(with: event(.leftMouseDragged, row: 2, in: table, window: window))
        table.mouseUp(with: event(.leftMouseUp, row: 2, in: table, window: window))
        #expect(ran == [0])
    }

    /// A press on a row scrolled out of view (under the search bar or footer) runs nothing.
    @Test func pressOnARowScrolledOutOfViewRunsNothing() {
        let (window, table) = table()
        defer { window.closeAfterTest() }
        // A 30 pt list over a 90 pt table, scrolled to row 1: rows 0 and 2 are out of view.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 30, width: 200, height: 30))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 90))
        content.addSubview(scroll)
        window.contentView = content
        scroll.documentView = table
        table.frame = NSRect(x: 0, y: 0, width: 200, height: 90)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 1).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        table.mouseDown(with: event(.leftMouseDown, row: 2, in: table, window: window))
        #expect(!table.visibleRect.contains(table.rect(ofRow: 2)))
        #expect(ran.isEmpty)
    }

    @Test func pressOffEveryRowRunsNothing() {
        let (window, table) = table()
        defer { window.closeAfterTest() }
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        table.mouseDown(with: event(.leftMouseDown, row: -1, in: table, window: window))
        #expect(ran.isEmpty)
    }
}

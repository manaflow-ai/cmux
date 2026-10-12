import AppKit
@testable import CmuxNextPalette
import Testing

/// Palette rows act like menu rows: press, drag and release runs the row the release lands on,
/// and a release off every row runs nothing (cx-bopcl).
@MainActor
@Suite struct PalettePressTests {
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

    @Test func releaseRunsTheRowThePressEndsOn() {
        let (window, table) = table()
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        window.postEvent(event(.leftMouseDragged, row: 1, in: table, window: window), atStart: false)
        window.postEvent(event(.leftMouseUp, row: 1, in: table, window: window), atStart: false)
        table.mouseDown(with: event(.leftMouseDown, row: 0, in: table, window: window))
        #expect(ran == [1])
    }

    @Test func releaseOffEveryRowRunsNothing() {
        let (window, table) = table()
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        window.postEvent(event(.leftMouseDragged, row: -1, in: table, window: window), atStart: false)
        window.postEvent(event(.leftMouseUp, row: -1, in: table, window: window), atStart: false)
        table.mouseDown(with: event(.leftMouseDown, row: 0, in: table, window: window))
        #expect(ran.isEmpty)
    }
}

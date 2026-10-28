import AppKit
@testable import CmuxNextPalette
import Testing

/// Lawrence 2026-10-19: "mouse down to immediately open", Cmd+P rows included. A press on a
/// visible row runs it at once; the drag and release that follow run nothing more. A press off
/// every visible row runs nothing.
@MainActor
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
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        table.mouseDown(with: event(.leftMouseDown, row: 1, in: table, window: window))
        #expect(ran == [1])
    }

    @Test func dragAndReleaseAfterThePressRunNothingMore() {
        let (window, table) = table()
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
        var ran: [Int] = []
        table.onClick = { ran.append($0) }
        table.mouseDown(with: event(.leftMouseDown, row: -1, in: table, window: window))
        #expect(ran.isEmpty)
    }

    // MARK: The Actions menu's press, drag and release (no `nextEvent(matching:)` loop)

    /// An open Actions menu with five rows; the menu is rebuilt with each hover, as the palette's render does.
    @MainActor private final class Menu {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = PaletteActionsMenuView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        var state: PaletteActionsMenuState
        var hovered: [Int] = []
        var ran: [Int] = []

        init() {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView = view
            let commands = (0..<5).map { PaletteCommand(id: "c\($0)", title: "Command \($0)", symbol: "return", effect: .perform {}) }
            state = PaletteActionsMenuState(itemID: "item", itemTitle: "Item", commands: commands)
            view.update(state, alternateID: nil)
            view.layoutSubtreeIfNeeded() // sync-layout: the test reads the rows' frames
            view.onHover = { [unowned self] index in
                hovered.append(index)
                // The palette renders the new selection: every row is replaced while the press is held.
                state.selectedIndex = index
                view.update(state, alternateID: nil)
                view.layoutSubtreeIfNeeded() // sync-layout: the next event hit-tests the new rows
            }
            view.onRun = { [unowned self] in ran.append($0) }
        }

        func rows() -> [PaletteMenuRow] {
            func collect(_ view: NSView) -> [PaletteMenuRow] {
                view.subviews.flatMap { subview -> [PaletteMenuRow] in
                    if let row = subview as? PaletteMenuRow { return [row] }
                    return collect(subview)
                }
            }
            return collect(view).sorted { $0.frame.minY < $1.frame.minY }
        }

        /// The center of row `index` in window coordinates; nil: a point inside the menu below every row.
        func point(_ index: Int?) -> NSPoint {
            guard let index else { return NSPoint(x: 150, y: 2) }
            let row = rows()[index]
            return row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, _ index: Int?) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point(index), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    /// A row's hit test answers with the menu, so the press's drag and release reach a view the rebuild keeps.
    @Test func theMenuTakesAPressOnARow() throws {
        let menu = Menu()
        defer { menu.window.close() }
        let contentView = try #require(menu.window.contentView)
        #expect(contentView.hitTest(menu.point(1)) === menu.view)
    }

    /// Press on a row, drag to another, release: the selection follows and the release runs the row it ends
    /// on, though every row was replaced on each hover. The press returns at once: no modal loop waits for the
    /// release (before this change `mouseDown` blocked in `nextEvent(matching:)` until it came).
    @Test func pressDragAndReleaseRunTheRowUnderTheRelease() throws {
        let menu = Menu()
        defer { menu.window.close() }
        menu.view.mouseDown(with: try menu.event(.leftMouseDown, 0))
        #expect(menu.hovered == [0])
        #expect(menu.ran.isEmpty, "the press ran a row before its release")
        menu.view.mouseDragged(with: try menu.event(.leftMouseDragged, 0))
        menu.view.mouseDragged(with: try menu.event(.leftMouseDragged, 2))
        menu.view.mouseDragged(with: try menu.event(.leftMouseDragged, 3))
        #expect(menu.hovered == [0, 2, 3], "a drag selects each new row once")
        menu.view.mouseUp(with: try menu.event(.leftMouseUp, 3))
        #expect(menu.ran == [3])
        // A later stray release runs nothing more.
        menu.view.mouseUp(with: try menu.event(.leftMouseUp, 1))
        #expect(menu.ran == [3])
    }

    /// Dragged off every row and released there: the press is taken back.
    @Test func aReleaseOffEveryRowRunsNothing() throws {
        let menu = Menu()
        defer { menu.window.close() }
        menu.view.mouseDown(with: try menu.event(.leftMouseDown, 1))
        menu.view.mouseDragged(with: try menu.event(.leftMouseDragged, nil))
        menu.view.mouseUp(with: try menu.event(.leftMouseUp, nil))
        #expect(menu.hovered == [1])
        #expect(menu.ran.isEmpty)
    }

    /// A press that starts off every row is not the menu's: it starts no press and runs nothing.
    @Test func aPressOffEveryRowStartsNoPress() throws {
        let menu = Menu()
        defer { menu.window.close() }
        menu.view.mouseDown(with: try menu.event(.leftMouseDown, nil))
        menu.view.mouseDragged(with: try menu.event(.leftMouseDragged, 2))
        menu.view.mouseUp(with: try menu.event(.leftMouseUp, 2))
        #expect(menu.hovered.isEmpty)
        #expect(menu.ran.isEmpty)
    }

    /// The menu closes under a held press: its release, wherever it lands later, runs nothing.
    @Test func aPressHeldWhileTheMenuClosesRunsNothing() throws {
        let menu = Menu()
        defer { menu.window.close() }
        let release = try menu.event(.leftMouseUp, 2)
        menu.view.mouseDown(with: try menu.event(.leftMouseDown, 2))
        menu.view.removeFromSuperview()
        menu.view.mouseUp(with: release)
        #expect(menu.ran.isEmpty)
    }
}

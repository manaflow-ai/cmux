import AppKit
import CmuxNextFiles
@testable import CmuxNextFilesUI
import Foundation
import Testing

/// #24776: a click below the last row of the Files pane's column view sends the browser's action
/// with no selected and no clicked column (-1); reading the item there raised NSRangeException
/// (`-[NSBrowser itemAtRow:inColumn:]`) and ended the app. The actions run through the browser's
/// own target/action, the path a real click takes.
@MainActor @Suite(.serialized)
struct FileColumnsClickTests {
    @MainActor final class Record {
        var browsed: [URL] = []
        var activated: [URL] = []
    }

    private nonisolated struct Listing: DirectoryListing {
        func list(_ folder: URL) async throws -> [FileEntry] {
            (0..<3).map { FileEntry(name: "folder-\($0)", in: folder, kind: .folder) }
                + [FileEntry(name: "note.txt", in: folder, kind: .file)]
        }
        func entry(at url: URL) async -> FileEntry? { nil }
    }

    private static func columns(_ record: Record) -> FileColumnsView {
        let actions = FilesPaneActions(
            activate: { record.activated.append($0.url) }, select: { _, _ in }, sort: { _ in }, rename: { _, _ in },
            drop: { _, _, _, _ in }, menu: { _ in NSMenu() }, key: { _ in false }, browse: { record.browsed.append($0) })
        return FileColumnsView(actions: actions, icons: FileIconProvider(), lister: Listing())
    }

    @Test func aClickOrDoubleClickOnNoRowDoesNotRaise() async throws {
        let record = Record()
        let columns = Self.columns(record)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = columns.view
        columns.view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        let browser = try #require(columns.view as? NSBrowser)
        browser.loadColumnZero()
        // Column zero lists off the main actor; wait until its rows are in.
        let root = columns.rootItem(for: browser)
        for _ in 0..<200 where columns.browser(browser, numberOfChildrenOfItem: root) == 0 { await Task.yield() }
        #expect(columns.browser(browser, numberOfChildrenOfItem: root) == 4)
        browser.reloadColumn(0)
        #expect(browser.lastColumn == 0)

        // A click below the rows: nothing selected, nothing clicked.
        #expect(browser.selectedColumn == -1)
        #expect(browser.clickedColumn == -1)
        #expect(browser.sendAction(browser.action, to: browser.target))
        #expect(browser.sendAction(browser.doubleAction, to: browser.target))
        #expect(record.browsed.isEmpty)
        #expect(record.activated.isEmpty)

        // A selected folder still browses into it.
        browser.selectRow(0, inColumn: 0)
        #expect(browser.sendAction(browser.action, to: browser.target))
        #expect(record.browsed.map(\.lastPathComponent) == ["folder-0"])
    }
}

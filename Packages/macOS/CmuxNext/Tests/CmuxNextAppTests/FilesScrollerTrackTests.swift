import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFiles
@testable import CmuxNextFilesUI
import Foundation
import Testing

/// Lawrence 2026-10-23 (msg 12114): "ensure horizontal and vertical scrollbars when there are
/// rows/columns do not have extra bg". The Files pane's list (a table with columns) and its column
/// view (an NSBrowser) scroll both ways; every bar in them is the shared thin scroller, on no track,
/// with no fill where the bars meet, also for columns the browser adds later.
@MainActor @Suite(.serialized)
struct FilesScrollerTrackTests {
    private static let actions = FilesPaneActions(
        activate: { _ in }, select: { _, _ in }, sort: { _ in }, rename: { _, _ in },
        drop: { _, _, _, _ in }, menu: { _ in NSMenu() }, key: { _ in false }, browse: { _ in })

    private nonisolated struct Listing: DirectoryListing {
        func list(_ folder: URL) async throws -> [FileEntry] {
            (0..<60).map { FileEntry(name: "folder-\($0)", in: folder, kind: .folder) }
        }
        func entry(at url: URL) async -> FileEntry? { nil }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// Every bar a scroll view under `view` shows is the thin scroller, overlay, with no table corner.
    private static func expectNoTracks(under view: NSView) {
        let scrolls = scrollViews(in: view)
        #expect(!scrolls.isEmpty)
        for scroll in scrolls {
            #expect(scroll.scrollerStyle == .overlay)
            if scroll.hasVerticalScroller { #expect(scroll.verticalScroller is ThinScroller, "\(scroll)") }
            if scroll.hasHorizontalScroller { #expect(scroll.horizontalScroller is ThinScroller, "\(scroll)") }
            if let table = scroll.documentView as? NSTableView { #expect(table.cornerView == nil) }
        }
    }

    @Test func theListsBarsHaveNoTrackOrCorner() throws {
        let list = FileListView(actions: Self.actions, icons: FileIconProvider())
        let scroll = try #require(list.view as? NSScrollView)
        #expect(scroll.hasVerticalScroller && scroll.hasHorizontalScroller)
        Self.expectNoTracks(under: scroll)
    }

    @Test func theColumnViewsBarsHaveNoTrack() async throws {
        let columns = FileColumnsView(actions: Self.actions, icons: FileIconProvider(), lister: Listing())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = columns.view
        columns.view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        let browser = try #require(columns.view as? NSBrowser)
        browser.loadColumnZero()
        // Columns past the width make the browser scroll sideways; each column scrolls its rows.
        // Each folder lists off the main actor, so open one level once the one above has listed.
        var path = ""
        for depth in 1...3 {
            // The checked read: before the column loads, a raw item(atRow:inColumn:) raises
            // (column <= lastColumn), the #24776 crash class.
            for _ in 0..<200 where browser.item(ifValidRow: 0, inColumn: depth - 1) == nil { await Task.yield() }
            path += "/folder-\(depth)"
            browser.setPath(path)
        }
        browser.tile()
        columns.view.layoutSubtreeIfNeeded()
        #expect(browser.lastColumn >= 1)
        Self.expectNoTracks(under: browser)
    }
}

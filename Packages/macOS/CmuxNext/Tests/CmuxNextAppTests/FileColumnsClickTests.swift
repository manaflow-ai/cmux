import AppKit
import CmuxNextFiles
@testable import CmuxNextFilesUI
import Foundation
import Testing

/// Issue #24776: a click in the Files pane's column view that leaves no selection
/// (empty space below the rows, a Cmd-click that deselects the last row) sent the
/// browser's action with `selectedColumn == -1`. The handler asked `NSBrowser` for
/// the item at that column and AppKit threw `NSRangeException` (index -1), which
/// quit the app. These tests drive the real `NSBrowser` action paths with no selection.
@MainActor
@Suite(.serialized)
struct FileColumnsClickTests {
    /// A lister that answers one fixed folder listing for every folder.
    struct FixedLister: DirectoryListing {
        let entries: [FileEntry]
        func list(_ folder: URL) async throws -> [FileEntry] { entries }
        func entry(at url: URL) async -> FileEntry? { nil }
    }

    /// Records what the column view asked the pane to do.
    final class Recorder {
        var browsed: [URL] = []
        var activated: [FileEntry] = []
    }

    private func makeColumns(_ recorder: Recorder, entries: [FileEntry] = []) throws -> (FileColumnsView, NSBrowser) {
        let actions = FilesPaneActions(
            activate: { recorder.activated.append($0) },
            select: { _, _ in },
            sort: { _ in },
            rename: { _, _ in },
            drop: { _, _, _, _ in },
            menu: { _ in NSMenu() },
            key: { _ in false },
            browse: { recorder.browsed.append($0) }
        )
        let columns = FileColumnsView(actions: actions, icons: FileIconProvider(), lister: FixedLister(entries: entries))
        let browser = try #require(columns.view as? NSBrowser)
        browser.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        browser.loadColumnZero()
        return (columns, browser)
    }

    @Test func clickWithNoSelectionDoesNotCrash() throws {
        let recorder = Recorder()
        let (columns, browser) = try makeColumns(recorder)
        #expect(browser.selectedColumn == -1)
        browser.sendAction(browser.action, to: browser.target)
        #expect(recorder.browsed.isEmpty)
        withExtendedLifetime(columns) {}
    }

    @Test func doubleClickWithNoClickedRowDoesNotCrash() throws {
        let recorder = Recorder()
        let (columns, browser) = try makeColumns(recorder)
        #expect(browser.clickedColumn == -1 || browser.clickedRow == -1)
        browser.sendAction(browser.doubleAction, to: browser.target)
        #expect(recorder.activated.isEmpty)
        withExtendedLifetime(columns) {}
    }

    @Test func clickOnARowStillBrowses() throws {
        let recorder = Recorder()
        let folder = FileEntry(url: URL(fileURLWithPath: "/tmp-24776"), kind: .folder)
        let (columns, browser) = try makeColumns(recorder)
        columns.show([folder], of: URL(fileURLWithPath: "/"), selection: [])
        browser.loadColumnZero()
        browser.selectRow(0, inColumn: 0)
        browser.sendAction(browser.action, to: browser.target)
        #expect(recorder.browsed == [folder.url])
        withExtendedLifetime(columns) {}
    }
}

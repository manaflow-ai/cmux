import AppKit
@testable import CmuxNextApp
import CmuxNextBookmarks
import CmuxNextDaemon
import Foundation
import Testing

/// The home daemon (`bookmarks-v1`) is the only bookmark writer (layer-ownership.md V-11). Before
/// it serves bookmarks, an edit used to go into `bookmarks.json` and show from there; the daemon
/// later got only that file's creates, so a move, rename or delete made in the window was lost.
/// Now the edit is refused and nothing is written.
@MainActor @Suite(.serialized)
struct BookmarkDaemonOnlyTests {
    @Test func anEditBeforeTheHomeDaemonServesBookmarksIsRefusedAndWritesNoFile() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmark-daemon-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarks = services.bookmarks
        bookmarks.start(directory: directory, importStore: nil)
        #expect(!bookmarks.usesDaemon, "no home daemon is connected in this test")

        let page = BookmarkNode.bookmark(
            "Example", url: try #require(URL(string: "https://example.com/")), in: BookmarkRoot.bar.rawValue)
        #expect(throws: DaemonError.notConnected) {
            try bookmarks.apply(.create(page, index: nil), profile: "default")
        }
        #expect(bookmarks.tree("default").isEmpty, "a refused edit shows nowhere")
        #expect(!bookmarks.isLoaded("default"), "only the daemon's reply makes a tree loaded")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "bookmarks.json").path))
    }
}

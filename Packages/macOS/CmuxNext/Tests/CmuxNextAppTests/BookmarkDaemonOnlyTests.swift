import AppKit
@testable import CmuxNextApp
import CmuxNextBookmarks
import Foundation
import Testing

/// The home daemon (`bookmarks-v1`) is the only bookmark writer and holds the only tree
/// (layer-ownership.md V-11). Before it serves bookmarks an edit is refused with the capability
/// gate's own text, nothing shows and no file is written; the app keeps no tree a refused edit could
/// go into.
@MainActor @Suite(.serialized)
struct BookmarkDaemonOnlyTests {
    @Test func anEditBeforeTheHomeDaemonServesBookmarksIsRefusedAndWritesNoFile() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "bookmark-daemon-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarks = services.bookmarks
        bookmarks.start(directory: directory, importStore: nil)
        #expect(!bookmarks.usesDaemon, "no home daemon is connected in this test")

        let url = try #require(URL(string: "https://example.com/"))
        await #expect(throws: BookmarkService.Unavailable.self) {
            try await bookmarks.apply([.create(id: BookmarkID.make(), profile: "default", parent: BookmarkRoot.bar.rawValue,
                                               folder: false, title: "Example", url: url)])
        }
        #expect(bookmarks.statuses["default"] == nil, "a refused edit shows nowhere")
        #expect(bookmarks.bookmarkIDs(for: url, profile: "default") == nil, "the star's state stays unknown")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "bookmarks.json").path))
    }
}

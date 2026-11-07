import AppKit
import CmuxNextBookmarks
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Bookmarks page shows the daemon's rows; the app's tree can lag them. `open` and `openAll`
/// resolve a row the app's tree lacks, or holds with another URL, on the daemon's tree.
@MainActor @Suite
struct BookmarkPageHostTests {
    @MainActor final class Host: BookmarkPageHost {
        var mirror = BookmarkTree()
        var owner = BookmarkTree()
        var ownerReads = 0
        var opened: [String] = []
        func bookmarkProfile(ofTab key: String) -> String { "default" }
        func bookmarkTree(_ profile: String) -> BookmarkTree { mirror }
        func bookmarkOwnerTree(_ profile: String) async throws -> BookmarkTree { ownerReads += 1; return owner }
        var bookmarkFolderIconsSupported: Bool { false }
        func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { nil }
        func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { nil }
        var bookmarkIconRevision: Int { 0 }
        func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) {
            opened.append(node.url?.absoluteString ?? node.id)
        }
    }

    static func tree(_ url: String) throws -> BookmarkTree {
        var tree = BookmarkTree()
        try tree.apply(.create(.folder("Work", in: BookmarkRoot.bar.rawValue, id: "bm_folder"), index: nil))
        try tree.apply(.create(.bookmark("Docs", url: try #require(URL(string: url)), in: "bm_folder", id: "bm_docs"), index: nil))
        return tree
    }

    let context = PageCallContext(page: PageDescriptor.bookmarks.id)

    @Test func openUsesTheDaemonsRowWhenTheAppsTreeLags() async throws {
        let host = Host()
        host.owner = try Self.tree("https://new.example/")
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        // Not in the app's tree yet.
        _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_docs", "url": "https://new.example/"], context: context)
        // In it with the old URL.
        host.mirror = try Self.tree("https://old.example/")
        _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_docs", "url": "https://new.example/"], context: context)
        #expect(host.opened == ["https://new.example/", "https://new.example/"])
        #expect(host.ownerReads == 2)
        // The same row in both: no daemon read.
        host.mirror = host.owner
        _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_docs", "url": "https://new.example/"], context: context)
        #expect(host.ownerReads == 2)
    }

    @Test func openAllReadsTheFolderFromTheDaemon() async throws {
        let host = Host()
        host.owner = try Self.tree("https://new.example/")
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        _ = try await page.call("cmux.bookmarkPage.openAll", params: ["folder": "bm_folder"], context: context)
        #expect(host.opened == ["https://new.example/"])
    }
}

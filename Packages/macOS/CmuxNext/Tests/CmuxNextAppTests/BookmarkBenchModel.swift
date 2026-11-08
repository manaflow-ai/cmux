@testable import CmuxNextApp
import CmuxNextBookmarks
import Foundation

/// What ``BookmarksBarCostBench`` seeds and changes. The app keeps no tree: a profile's model is
/// the daemon's `bookmarks.status` for the pages on screen, so a change event's main-actor work is
/// applying one status whatever the profile holds; the tree's size stays in the daemon.
@MainActor
enum BookmarkBenchModel {
    /// `total` bookmarks, `bar` of them on the bar, the first one to `page`: as the daemon answers
    /// for a profile whose tabs all show `page`.
    static func seed(_ bookmarks: BookmarkService, profile: String, page: URL, bar: Int, total: Int) throws {
        // Before any tab shows the page, its answer is what the star's own edit leaves.
        bookmarks.noteBookmarks(["bm_bench_0"], url: page, profile: profile, barFilled: true)
        self.page = page
    }

    /// One daemon change event: the status read it starts lands with a new revision.
    static func change(_ bookmarks: BookmarkService, profile: String, round: Int) {
        guard let page else { return }
        bookmarks.applyStatus(status(revision: round + 1, page: page), profile: profile)
    }

    private static var page: URL?

    private static func status(revision: Int, page: URL) -> BookmarkRoutedClient.Status {
        BookmarkRoutedClient.Status(revision: revision, barFilled: true, matches: [page.absoluteString: ["bm_bench_0"]])
    }
}

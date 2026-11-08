@testable import CmuxNextApp
import CmuxNextBookmarks
import Foundation

/// What ``BookmarksBarCostBench`` seeds and changes, before the tree moved to the daemon: the app
/// holds the profile's whole tree, and a change event's main-actor work is building the tree from
/// the daemon's rows and fanning it out to every chrome.
@MainActor
enum BookmarkBenchModel {
    static func seed(_ bookmarks: BookmarkService, profile: String, page: URL, bar: Int, total: Int) throws {
        var nodes: [BookmarkNode] = []
        for index in 0..<bar {
            let url = index == 0 ? page : page.appending(path: "bar/\(index)")
            nodes.append(.bookmark("Bar \(index)", url: url, in: BookmarkRoot.bar.rawValue))
        }
        let folder = BookmarkNode.folder("Archive", in: BookmarkRoot.other.rawValue)
        nodes.append(folder)
        for index in 0..<(total - bar - 1) { nodes.append(.bookmark("Saved \(index)", url: page.appending(path: "saved/\(index)"), in: folder.id)) }
        rows = nodes
        bookmarks.trees[profile] = BookmarkTree(ordered: nodes)
    }

    static func change(_ bookmarks: BookmarkService, profile: String, round: Int) {
        bookmarks.trees[profile] = BookmarkTree(ordered: rows)
        bookmarks.changed(profiles: [profile])
    }

    private static var rows: [BookmarkNode] = []
}

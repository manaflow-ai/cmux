@testable import CmuxNextBookmarks
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chromium's bookmark events become the home daemon's ops, and the daemon's rows become the tree
/// Chromium syncs to (CmuxNextBookmarks `BookmarkChromium.swift`, moved out of the App with the
/// app's copy of the tree).
@MainActor @Suite
struct BookmarkChromiumMappingTests {
    @Test func idsRoundTripAndRootsStay() {
        let id = BookmarkID.make()
        let uuid = BookmarkID.chromium(id)
        #expect(UUID(uuidString: uuid) != nil)
        #expect(BookmarkID.cmux(chromium: uuid.uppercased()) == id)
        #expect(BookmarkID.chromium("bar") == "bar" && BookmarkID.cmux(chromium: "other") == "other")
    }

    @Test func anAddedLinkIsOneCreateAndABadURLIsRefused() throws {
        let uuid = "0123abcd-0000-4000-8000-00000000beef"
        let node = try #require(CEFBookmarkNode(["id": uuid, "parent": "bar", "index": 2, "kind": "url", "title": "Docs",
                                                 "url": "https://example.com/", "added_ms": 1_000.0]))
        let ops = try CEFBookmarkEvent.added([node]).bookmarkOps(profile: "default")
        let create = try #require(ops.first?.json.foundationObject as? [String: Any])
        #expect(create["op"] as? String == "create")
        #expect(create["id"] as? String == BookmarkID.cmux(chromium: uuid))
        #expect(create["parent"] as? String == "bar")
        #expect(create["index"] as? Double == 2)
        #expect(create["url"] as? String == "https://example.com/")
        #expect(create["created_ms"] as? Double == 1_000)
        #expect(throws: BookmarkError.invalidURL) {
            try CEFBookmarkEvent.changed(id: uuid, title: "x", url: "").bookmarkOps(profile: "default")
        }
        #expect(try CEFBookmarkEvent.reordered(parent: "bar", children: [uuid, uuid]).bookmarkOps(profile: "default").count == 2)
    }

    /// `bookmarks.apply` takes at most 256 ops: a reorder of 257 children goes as two batches in
    /// order (256, then 1), not one batch the daemon refuses whole.
    @Test func aBigReorderGoesInOrderedBatchesTheDaemonTakes() throws {
        let children = (0..<257).map { _ in BookmarkID.chromium(BookmarkID.make()) }
        let ops = try CEFBookmarkEvent.reordered(parent: "bar", children: children).bookmarkOps(profile: "default")
        #expect(ops.count == 257)
        let batches = BookmarkRoutedClient.batches(ops)
        #expect(batches.map(\.count) == [256, 1])
        #expect(batches.allSatisfy { $0.count <= BookmarkRoutedClient.maxOps })
        #expect(Array(batches.joined()) == ops, "every op, in Chromium's order")
        let last = try #require(batches.last?.first?.json.foundationObject as? [String: Any])
        #expect(last["index"] as? Double == 256)
        #expect(BookmarkRoutedClient.batches([]).isEmpty)
        #expect(BookmarkRoutedClient.batches(Array(ops.prefix(256))).count == 1)
    }

    @Test func theSyncedTreeKeepsListingOrderInChromiumIds() throws {
        let folder = BookmarkNode(id: BookmarkID.make(), parent: "bar", kind: .folder, title: "Work")
        let link = BookmarkNode(id: BookmarkID.make(), parent: folder.id, kind: .url, title: "Docs", url: URL(string: "https://example.com/"))
        let json = BookmarkID.chromiumTree([folder, link])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        #expect(nodes.map { $0["id"] as? String } == [BookmarkID.chromium(folder.id), BookmarkID.chromium(link.id)])
        #expect(nodes[1]["parent"] as? String == BookmarkID.chromium(folder.id))
        #expect(nodes.map { $0["kind"] as? String } == ["folder", "url"])
    }
}

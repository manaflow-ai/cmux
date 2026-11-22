import CmuxNextBookmarks
import Foundation
import Testing

@Suite struct BookmarkFileStoreTests {
    @Test func savesAndLoadsEveryProfileInTreeOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bookmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "bookmarks.json")
        var tree = BookmarkTree()
        try tree.apply(.create(.folder("F", in: "bar", id: "f", created: Date(timeIntervalSince1970: 10)), index: nil))
        try tree.apply(.create(.bookmark("A", url: URL(string: "https://a.com")!, in: "f", id: "a",
                                         created: Date(timeIntervalSince1970: 11)), index: nil))
        try tree.apply(.update(id: "a", lastUsed: .set(Date(timeIntervalSince1970: 12))))

        let store = BookmarkFileStore(file: file)
        try await store.save(profile: "default", nodes: tree.ordered)
        try await store.save(profile: "p2", nodes: [.bookmark("B", url: URL(string: "https://b.com")!, in: "other", id: "b")])

        let reloaded = await BookmarkFileStore(file: file).load()
        #expect(BookmarkTree(ordered: reloaded["default"] ?? []) == tree)
        #expect(reloaded["p2"]?.map(\.id) == ["b"])

        try await store.save(profile: "p2", nodes: [])
        #expect(await BookmarkFileStore(file: file).load().keys.sorted() == ["default"])
        try await store.remove()
        #expect(await !store.exists)
    }
}

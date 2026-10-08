import CmuxNextBookmarks
import Foundation
import Testing

@Suite struct BookmarkImportTests {
    private let bar = BookmarkRoot.bar.rawValue

    private func counter() -> () -> String {
        var next = 0
        return {
            next += 1
            return "n\(next)"
        }
    }

    private func item(_ title: String, _ path: [String]) -> BookmarkImportItem {
        BookmarkImportItem(title: title, url: URL(string: "https://\(title.lowercased()).com")!, folderPath: path, created: nil)
    }

    @Test func sourceImportBuildsFoldersInFirstUseOrderAndStripsTheSharedRoot() throws {
        var tree = BookmarkTree()
        try tree.apply(.create(.bookmark("Mine", url: URL(string: "https://mine.com")!, in: bar, id: "mine"), index: nil))
        let items = [item("A", ["Bookmarks Bar"]), item("B", ["Bookmarks Bar", "Work"]), item("C", ["Bookmarks Bar"]),
                     item("D", ["Bookmarks Bar", "Work", "Deep"])]
        try tree.apply(BookmarkImportPlan.source(title: "Chrome · Work", sourceKey: "chrome/Default", items: items), makeID: counter())
        let folder = try #require(tree.folder(sourceKey: "chrome/Default"))
        #expect(tree.children(of: bar).map(\.title) == ["Mine", "Chrome · Work"])
        #expect(tree.children(of: folder.id).map(\.title) == ["A", "Work", "C"])
        let work = try #require(tree.children(of: folder.id).first { $0.isFolder })
        #expect(tree.children(of: work.id).map(\.title) == ["B", "Deep"])
    }

    @Test func sourceReimportReplacesInPlace() throws {
        var tree = BookmarkTree()
        try tree.apply(BookmarkImportPlan.source(title: "Safari", sourceKey: "safari/x", items: [item("A", ["Favorites"]), item("B", ["Menu"])]))
        try tree.apply(.create(.bookmark("After", url: URL(string: "https://after.com")!, in: bar, id: "after"), index: nil))
        let first = try #require(tree.folder(sourceKey: "safari/x"))
        try tree.apply(BookmarkImportPlan.source(title: "Safari 2", sourceKey: "safari/x", items: [item("C", ["Favorites"])]))
        let second = try #require(tree.folder(sourceKey: "safari/x"))
        #expect(first.id == second.id)
        #expect(second.title == "Safari 2")
        #expect(tree.children(of: bar).map(\.title) == ["Safari 2", "After"])
        #expect(tree.children(of: second.id).map(\.title) == ["C"])
        #expect(!tree.isBookmarked(URL(string: "https://a.com")!))
        #expect(tree.count == 3)
    }

    @Test func importKeepsSourceDates() throws {
        var tree = BookmarkTree()
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let dated = BookmarkImportItem(title: "Old", url: URL(string: "https://old.com")!, folderPath: [], created: date)
        try tree.apply(BookmarkImportPlan.source(title: "Firefox", sourceKey: "firefox/p", items: [dated]))
        #expect(tree.bookmarks.first?.created == date)
    }

    @Test func migrationOfLegacyImportBatchesIsIdempotent() throws {
        var tree = BookmarkTree()
        let items = [item("A", ["Bookmarks Bar"]), item("B", ["Other Bookmarks"])]
        for _ in 0..<3 {
            try tree.apply(BookmarkImportPlan.source(title: "Chrome", sourceKey: "chrome/Default", items: items))
        }
        #expect(tree.bookmarks.count == 2)
        #expect(tree.children(of: bar).count == 1)
    }
}

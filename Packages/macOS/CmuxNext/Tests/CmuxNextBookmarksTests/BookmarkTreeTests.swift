import CmuxNextBookmarks
import Foundation
import Testing

@Suite struct BookmarkTreeTests {
    private let bar = BookmarkRoot.bar.rawValue
    private let other = BookmarkRoot.other.rawValue

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func titles(_ tree: BookmarkTree, _ parent: String) -> [String] {
        tree.children(of: parent).map(\.title)
    }

    private func sample() throws -> BookmarkTree {
        var tree = BookmarkTree()
        try tree.apply(.create(.bookmark("A", url: url("https://a.com"), in: bar, id: "a"), index: nil))
        try tree.apply(.create(.bookmark("B", url: url("https://b.com"), in: bar, id: "b"), index: nil))
        try tree.apply(.create(.folder("Work", in: bar, id: "work"), index: nil))
        try tree.apply(.create(.bookmark("C", url: url("https://c.com"), in: "work", id: "c"), index: nil))
        try tree.apply(.create(.folder("Deep", in: "work", id: "deep"), index: nil))
        return tree
    }

    @Test func createAppendsAndInsertsAtIndex() throws {
        var tree = try sample()
        #expect(titles(tree, bar) == ["A", "B", "Work"])
        try tree.apply(.create(.bookmark("Z", url: url("https://z.com"), in: bar, id: "z"), index: 1))
        #expect(titles(tree, bar) == ["A", "Z", "B", "Work"])
        try tree.apply(.create(.bookmark("Y", url: url("https://y.com"), in: bar, id: "y"), index: 99))
        #expect(titles(tree, bar).last == "Y")
    }

    @Test func createIsIdempotentForAnExistingID() throws {
        var tree = try sample()
        let change = try tree.apply(.create(.bookmark("Again", url: url("https://a.com"), in: other, id: "a"), index: nil))
        #expect(change.isEmpty)
        #expect(tree.node("a")?.title == "A")
    }

    @Test func createRefusesUnknownParentAndFolderURL() throws {
        var tree = try sample()
        #expect(throws: BookmarkError.invalidParent("nope")) {
            try tree.apply(.create(.bookmark("X", url: url("https://x.com"), in: "nope"), index: nil))
        }
        #expect(throws: BookmarkError.invalidParent("a")) {
            try tree.apply(.create(.bookmark("X", url: url("https://x.com"), in: "a"), index: nil))
        }
        var folder = BookmarkNode.folder("F", in: bar)
        folder.url = url("https://f.com")
        #expect(throws: BookmarkError.invalidKind) { try tree.apply(.create(folder, index: nil)) }
        let relative = BookmarkNode(parent: bar, kind: .url, title: "R", url: URL(string: "relative/path"))
        #expect(throws: BookmarkError.invalidURL) { try tree.apply(.create(relative, index: nil)) }
    }

    @Test func moveUsesTheFinalIndexWithinTheSameParent() throws {
        var tree = try sample()
        try tree.apply(.move(id: "a", parent: bar, index: 2))
        #expect(titles(tree, bar) == ["B", "Work", "A"])
        try tree.apply(.move(id: "a", parent: bar, index: 0))
        #expect(titles(tree, bar) == ["A", "B", "Work"])
        let unchanged = try tree.apply(.move(id: "a", parent: bar, index: 0))
        #expect(unchanged.isEmpty)
    }

    @Test func moveBetweenFoldersAndClampsIndex() throws {
        var tree = try sample()
        try tree.apply(.move(id: "b", parent: "work", index: 0))
        #expect(titles(tree, bar) == ["A", "Work"])
        #expect(titles(tree, "work") == ["B", "C", "Deep"])
        try tree.apply(.move(id: "c", parent: other, index: 50))
        #expect(titles(tree, other) == ["C"])
        #expect(tree.node("c")?.parent == other)
    }

    @Test func moveRefusesCycles() throws {
        var tree = try sample()
        #expect(throws: BookmarkError.cycle) { try tree.apply(.move(id: "work", parent: "deep", index: 0)) }
        #expect(throws: BookmarkError.cycle) { try tree.apply(.move(id: "work", parent: "work", index: 0)) }
        #expect(tree.node("work")?.parent == bar)
    }

    @Test func deleteRemovesTheSubtree() throws {
        var tree = try sample()
        let change = try tree.apply(.delete(id: "work"))
        #expect(Set(change.deleted) == ["work", "c", "deep"])
        #expect(tree.count == 2)
        #expect(titles(tree, bar) == ["A", "B"])
        #expect(!tree.isBookmarked(url("https://c.com")))
        #expect(throws: BookmarkError.notFound("work")) { try tree.apply(.delete(id: "work")) }
    }

    @Test func updateEditsFieldsAndRefusesURLOnFolder() throws {
        var tree = try sample()
        try tree.apply(.update(id: "a", title: "Alpha", url: url("https://alpha.com"), lastUsed: .set(Date(timeIntervalSince1970: 5))))
        #expect(tree.node("a")?.title == "Alpha")
        #expect(tree.isBookmarked(url("https://alpha.com")))
        #expect(!tree.isBookmarked(url("https://a.com")))
        #expect(tree.node("a")?.lastUsed == Date(timeIntervalSince1970: 5))
        try tree.apply(.update(id: "a", lastUsed: .clear))
        #expect(tree.node("a")?.lastUsed == nil)
        #expect(throws: BookmarkError.invalidKind) { try tree.apply(.update(id: "work", url: url("https://x.com"))) }
    }

    @Test func isBookmarkedComparesCanonicalURLs() throws {
        let tree = try sample()
        #expect(tree.isBookmarked(url("https://A.COM/")))
        #expect(tree.isBookmarked(url("https://a.com")))
        #expect(!tree.isBookmarked(url("https://a.com/page")))
        #expect(tree.bookmarks(for: url("HTTPS://c.com")).map(\.id) == ["c"])
    }

    @Test func orderedIsPreorderAndRoundTrips() throws {
        let tree = try sample()
        #expect(tree.ordered.map(\.id) == ["a", "b", "work", "c", "deep"])
        #expect(BookmarkTree(ordered: tree.ordered) == tree)
        #expect(BookmarkTree(ordered: tree.ordered.shuffledStable()).ordered.map(\.id).count == 5)
    }

    @Test func orphansGoToOtherBookmarks() throws {
        let orphan = BookmarkNode.bookmark("O", url: url("https://o.com"), in: "missing-folder", id: "o")
        let tree = BookmarkTree(ordered: [orphan])
        #expect(tree.node("o")?.parent == other)
        #expect(titles(tree, other) == ["O"])
    }

    @Test func folderPathAndRoot() throws {
        let tree = try sample()
        #expect(tree.folderPath(of: "deep") == ["bar", "Work"])
        #expect(tree.root(of: "c") == .bar)
        #expect(tree.depth(of: "deep") == 2)
    }

    @Test func depthLimitIsEnforced() throws {
        var tree = BookmarkTree()
        var parent = bar
        for level in 0..<BookmarkLimits.depth {
            try tree.apply(.create(.folder("L\(level)", in: parent, id: "f\(level)"), index: nil))
            parent = "f\(level)"
        }
        #expect(throws: BookmarkError.tooDeep) { try tree.apply(.create(.folder("Too", in: parent), index: nil)) }
    }
}

private extension Array {
    /// Reversed: children may arrive before their parents.
    func shuffledStable() -> [Element] { reversed() }
}

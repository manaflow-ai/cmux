import Testing

@testable import CmuxFileSearch

@Suite("Grouped result tree")
struct FileSearchResultTreeTests {
    private func matches(_ lines: [Int]) -> [FileSearchMatch] {
        lines.map { FileSearchMatch(lineNumber: $0, column: 1, length: 1, preview: "x", previewMatchRange: 0..<1) }
    }

    private func makeTree() -> FileSearchResultTree {
        FileSearchResultTree { path in String(path.dropFirst("/root/".count)) }
    }

    @Test("Files group in first-seen order and report inserted rows")
    func grouping() {
        let tree = makeTree()
        let change = tree.apply([
            FileSearchFileMatches(path: "/root/a", matches: matches([1, 2])),
            FileSearchFileMatches(path: "/root/b", matches: matches([5])),
        ])

        #expect(change.insertedFiles == 0..<2)
        #expect(change.grownFiles.isEmpty)
        #expect(tree.files.map(\.relativePath) == ["a", "b"])
        #expect(tree.matchCount == 3)
        #expect(tree.fileCount == 2)
    }

    @Test("A file reported again merges into its existing row")
    func merging() {
        let tree = makeTree()
        tree.apply([FileSearchFileMatches(path: "/root/a", matches: matches([1]))])
        let firstNode = tree.files[0]
        let change = tree.apply([
            FileSearchFileMatches(path: "/root/a", matches: matches([7, 8])),
            FileSearchFileMatches(path: "/root/c", matches: matches([2])),
        ])

        #expect(tree.files[0] === firstNode)
        #expect(tree.files[0].matches.map(\.lineNumber) == [1, 7, 8])
        #expect(change.grownFiles.map(\.fileIndex) == [0])
        #expect(change.grownFiles.map(\.previousCount) == [1])
        #expect(change.insertedFiles == 1..<2)
        #expect(tree.matchCount == 4)
    }

    @Test("Match row objects are stable and point at their file")
    func matchNodes() {
        let tree = makeTree()
        tree.apply([FileSearchFileMatches(path: "/root/a", matches: matches([1, 2]))])
        let node = tree.files[0].matchNode(at: 1)

        #expect(tree.files[0].matchNode(at: 1) === node)
        #expect(node.match.lineNumber == 2)
        #expect(tree.position(of: node) == FileSearchResultPosition(fileIndex: 0, matchIndex: 1))
    }

    @Test("Next and previous walk matches across files and wrap")
    func navigation() {
        let tree = makeTree()
        tree.apply([
            FileSearchFileMatches(path: "/root/a", matches: matches([1, 2])),
            FileSearchFileMatches(path: "/root/b", matches: matches([3])),
        ])
        let a0 = FileSearchResultPosition(fileIndex: 0, matchIndex: 0)
        let a1 = FileSearchResultPosition(fileIndex: 0, matchIndex: 1)
        let b0 = FileSearchResultPosition(fileIndex: 1, matchIndex: 0)

        #expect(tree.nextMatch(after: nil) == a0)
        #expect(tree.nextMatch(after: a0) == a1)
        #expect(tree.nextMatch(after: a1) == b0)
        #expect(tree.nextMatch(after: b0) == a0)
        #expect(tree.nextMatch(after: FileSearchResultPosition(fileIndex: 1, matchIndex: nil)) == b0)

        #expect(tree.previousMatch(before: nil) == b0)
        #expect(tree.previousMatch(before: b0) == a1)
        #expect(tree.previousMatch(before: a0) == b0)
        #expect(tree.previousMatch(before: FileSearchResultPosition(fileIndex: 1, matchIndex: nil)) == a1)
    }

    @Test("Dismissing a file removes its matches and keeps later files addressable")
    func dismiss() {
        let tree = makeTree()
        tree.apply([
            FileSearchFileMatches(path: "/root/a", matches: matches([1, 2])),
            FileSearchFileMatches(path: "/root/b", matches: matches([3])),
        ])
        let first = tree.files[0]
        #expect(tree.remove(first))
        #expect(!tree.remove(first))
        #expect(tree.files.map(\.relativePath) == ["b"])
        #expect(tree.matchCount == 1)
        #expect(tree.index(of: tree.files[0]) == 0)
        let change = tree.apply([FileSearchFileMatches(path: "/root/b", matches: matches([4]))])
        #expect(change.grownFiles.map(\.fileIndex) == [0])
    }

    @Test("Navigation on an empty tree finds nothing")
    func emptyNavigation() {
        let tree = makeTree()
        #expect(tree.nextMatch(after: nil) == nil)
        #expect(tree.previousMatch(before: nil) == nil)
    }
}

@Suite("Search history")
struct FileSearchHistoryTests {
    @Test("Recording deduplicates, keeps newest last and caps size")
    func recording() {
        var history = FileSearchHistory(capacity: 3)
        for entry in ["a", "b", "a", "c", "d", ""] { history.record(entry) }
        #expect(history.entries == ["a", "c", "d"])
    }

    @Test("Up walks back, down walks forward and restores the draft")
    func cursor() {
        let history = FileSearchHistory(entries: ["one", "two", "three"])
        var cursor = FileSearchHistoryCursor()

        #expect(cursor.previous(in: history, current: "dra") == "three")
        #expect(cursor.previous(in: history, current: "three") == "two")
        #expect(cursor.previous(in: history, current: "two") == "one")
        #expect(cursor.previous(in: history, current: "one") == nil)
        #expect(cursor.next(in: history) == "two")
        #expect(cursor.next(in: history) == "three")
        #expect(cursor.next(in: history) == "dra")
        #expect(!cursor.isBrowsing)
        #expect(cursor.next(in: history) == nil)
    }

    @Test("Up skips the newest entry when the field already shows it")
    func skipsCurrent() {
        let history = FileSearchHistory(entries: ["one", "two"])
        var cursor = FileSearchHistoryCursor()
        #expect(cursor.previous(in: history, current: "two") == "one")
    }
}

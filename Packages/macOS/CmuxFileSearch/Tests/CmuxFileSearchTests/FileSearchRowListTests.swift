import Foundation
import Testing

@testable import CmuxFileSearch

@Suite("Flat result rows")
struct FileSearchRowListTests {
    private func group(_ path: String, _ lines: [Int]) -> FileSearchFileMatches {
        FileSearchFileMatches(path: path, matches: lines.map {
            FileSearchMatch(lineNumber: $0, column: 1, length: 1, preview: "x", previewMatchRange: 0..<1)
        })
    }

    @Test("Streaming appends rows and refreshes the grown file's row")
    func appends() {
        let tree = FileSearchResultTree { $0 }
        let rows = FileSearchRowList(tree: tree)
        #expect(rows.apply(tree.apply([group("a", [1, 2])])) == .appended(inserted: 0..<3, refreshedRows: []))
        #expect(rows.apply(tree.apply([group("a", [3]), group("b", [1])])) ==
            .appended(inserted: 3..<6, refreshedRows: IndexSet(integer: 0)))
        #expect(rows.rows.map(\.matchIndex) == [nil, 0, 1, 2, nil, 0])
    }

    @Test("A file other than the last gaining matches reloads in order")
    func earlierFileReloads() {
        let tree = FileSearchResultTree { $0 }
        let rows = FileSearchRowList(tree: tree)
        _ = rows.apply(tree.apply([group("a", [1]), group("b", [1])]))
        #expect(rows.apply(tree.apply([group("a", [2])])) == .reload)
        #expect(rows.rows.map(\.fileIndex) == [0, 0, 0, 1, 1])
    }

    @Test("Collapsed files show only their file row; lookups find visible rows")
    func collapse() {
        let tree = FileSearchResultTree { $0 }
        let rows = FileSearchRowList(tree: tree)
        _ = rows.apply(tree.apply([group("a", [1, 2]), group("b", [1])]))
        tree.files[0].isExpanded = false
        rows.rebuild()
        #expect(rows.count == 3)
        #expect(rows.row(of: FileSearchResultPosition(fileIndex: 1, matchIndex: 0)) == 2)
        #expect(rows.row(of: FileSearchResultPosition(fileIndex: 0, matchIndex: 1)) == nil)
        #expect(rows.fileRow(containing: 2) == 1)
    }
}

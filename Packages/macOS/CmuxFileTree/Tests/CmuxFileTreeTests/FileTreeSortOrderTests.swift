import Foundation
import Testing
@testable import CmuxFileTree

@Suite struct FileTreeSortOrderTests {
    private func names(_ entries: [FileTreeEntry]) -> [String] { entries.map(\.name) }

    private func file(_ name: String, size: Int64 = 0, time: TimeInterval = 0) -> FileTreeEntry {
        FileTreeEntry(name: name, path: "/r/" + name, kind: .file, size: size, modificationTime: time)
    }

    private func folder(_ name: String) -> FileTreeEntry {
        FileTreeEntry(name: name, path: "/r/" + name, kind: .directory)
    }

    @Test func nameOrderIsNaturalAndCaseInsensitive() {
        let input = ["file10", "File2", "file1", "b", "A", "file02"].map { file($0) }
        #expect(names(FileTreeSortOrder.standard.sorted(input)) == ["A", "b", "file1", "File2", "file02", "file10"])
    }

    @Test func nameOrderMatchesFinderStandardCompareForCommonNames() {
        let raw = ["README.md", "readme.txt", "src", "Sources", "a10.js", "a9.js", "_private", "Zeta", "alpha", "ALPHA2"]
        let expected = raw.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(names(FileTreeSortOrder(foldersFirst: false).sorted(raw.map { file($0) })) == expected)
    }

    @Test func foldersStayFirstUnlessDisabled() {
        let input = [file("a"), folder("z"), file("b"), folder("c")]
        #expect(names(FileTreeSortOrder.standard.sorted(input)) == ["c", "z", "a", "b"])
        #expect(names(FileTreeSortOrder(foldersFirst: false).sorted(input)) == ["a", "b", "c", "z"])
    }

    @Test func descendingReversesThePrimaryKey() {
        let input = [file("a"), file("c"), file("b")]
        #expect(names(FileTreeSortOrder(ascending: false).sorted(input)) == ["c", "b", "a"])
    }

    @Test func sizeAndDateKeysBreakTiesByName() {
        let input = [file("b", size: 5, time: 2), file("a", size: 5, time: 2), file("c", size: 1, time: 9)]
        #expect(names(FileTreeSortOrder(key: .size).sorted(input)) == ["c", "a", "b"])
        #expect(names(FileTreeSortOrder(key: .dateModified, ascending: false).sorted(input)) == ["c", "a", "b"])
    }

    @Test func kindGroupsByExtension() {
        let input = [file("b.swift"), file("a.md"), file("c.swift"), file("Makefile")]
        #expect(names(FileTreeSortOrder(key: .kind).sorted(input)) == ["Makefile", "a.md", "b.swift", "c.swift"])
    }
}

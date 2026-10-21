import Foundation
import Testing
@testable import CmuxNextFiles

/// Finder name order, sorting by column, and the filter field's matcher.
struct FileOrderTests {
    private static let corpus = [
        "file 10.txt", "file 2.txt", "File 1.txt", "file-3", "file_4", "file.5", "a", "B", "c", "z",
        "_underscore", "-dash", "1", "02", "10", "9 lives", "abc", "abd", "ab", "Readme.md", "readme 2.md",
        "img001.png", "img2.png", "img10.png", "x y", "x-y", "x_y", "(paren)", "[bracket]", "~tilde", "$dollar",
    ]

    @Test func nameKeyMatchesFinderOrderOnASCII() {
        let byFinder = Self.corpus.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let byKey = Self.corpus.sorted { FileNameSortKey($0) < FileNameSortKey($1) || (FileNameSortKey($0) == FileNameSortKey($1) && $0 < $1) }
        #expect(byKey == byFinder)
    }

    @Test(arguments: [("file 2", "file 10"), ("img2", "img10"), ("a", "B"), ("1", "a"), ("_x", "1"), ("é", "f"), ("007", "8")])
    func nameKeyPairs(first: String, second: String) {
        #expect(FileNameSortKey(first) < FileNameSortKey(second))
    }

    @Test func caseAndAccentTieThenRawNameBreaksIt() {
        #expect(FileNameSortKey("Résumé") == FileNameSortKey("resume"))
        let a = FileEntry(url: URL(fileURLWithPath: "/x/Resume"), kind: .file)
        let b = FileEntry(url: URL(fileURLWithPath: "/x/resume"), kind: .file)
        #expect(FileSortOrder().sorted([b, a]).map(\.name) == ["Resume", "resume"])
    }

    @Test func sortsBySizeDateAndKeepsFoldersFirst() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let entries = [
            FileEntry(url: URL(fileURLWithPath: "/x/big"), kind: .file, size: 900, modified: old),
            FileEntry(url: URL(fileURLWithPath: "/x/small"), kind: .file, size: 1, modified: new),
            FileEntry(url: URL(fileURLWithPath: "/x/zdir"), kind: .folder, modified: old),
        ]
        #expect(FileSortOrder(field: .size, ascending: false).sorted(entries).map(\.name) == ["big", "small", "zdir"])
        #expect(FileSortOrder(field: .modified, ascending: false).sorted(entries).map(\.name) == ["small", "big", "zdir"])
        #expect(FileSortOrder(field: .name, foldersFirst: true).sorted(entries).map(\.name) == ["zdir", "big", "small"])
        #expect(FileSortOrder(field: .kind).sorted(entries).first?.name == "zdir")
    }

    @Test func sortingAHundredThousandNamesIsFast() {
        let parent = URL(fileURLWithPath: "/x")
        let entries = (1...100_000).reversed().map { FileEntry(name: "file-\($0).txt", in: parent, kind: .file) }
        let clock = ContinuousClock()
        var sorted: [FileEntry] = []
        let elapsed = clock.measure { sorted = FileSortOrder().sorted(entries) }
        #expect(sorted.first?.name == "file-1.txt")
        #expect(sorted[1].name == "file-2.txt")
        #expect(sorted.last?.name == "file-100000.txt")
        // localizedStandardCompare in a comparator takes ~400 ms here.
        #expect(elapsed < .milliseconds(250))
    }

    @Test(arguments: [("rep", "Report.pdf", true), ("PORT", "report.pdf", true), ("resume", "Résumé.doc", true),
                      ("x", "report.pdf", false), ("", "anything", true), ("日本", "日本語.txt", true)])
    func matcher(text: String, name: String, matches: Bool) {
        #expect(FileNameMatcher(text).matches(name) == matches)
    }
}

import Foundation
import Testing
@testable import CmuxNextFiles

/// The Files pane's recursive name search (plans/cmux-next/files-finder-parity-DESIGN.md, 4.2).
struct FolderNameIndexTests {
    private static func tree() throws -> TempFolder {
        let temp = try TempFolder()
        for sub in ["src", "src/ui", "docs", "Café", ".git", "Tool.app", "Tool.app/Contents"] { try temp.folder(sub) }
        try temp.file("report.txt")
        try temp.file("Report Final.pdf", in: "docs")
        try temp.file("old-report.md", in: "docs")
        try temp.file("main.swift", in: "src")
        try temp.file("ReportView.swift", in: "src/ui")
        try temp.file("résumé.pdf", in: "Café")
        try temp.file("report-hidden", in: ".git")
        try temp.file("report-in-app", in: "Tool.app/Contents")
        return temp
    }

    @Test func findsNestedNamesBySubstring() throws {
        let temp = try Self.tree()
        let index = try FolderNameIndex.build(root: temp.url)
        let paths = Set(index.search("report").map(\.relativePath))
        #expect(paths == ["report.txt", "docs/Report Final.pdf", "docs/old-report.md", "src/ui/ReportView.swift"])
    }

    @Test func ranksExactThenPrefixThenWordThenSubstring() throws {
        let temp = try TempFolder()
        for name in ["myreport", "old-report", "report", "reports-2026", "report.txt"] { try temp.file(name) }
        let index = try FolderNameIndex.build(root: temp.url)
        let names = index.search("report").map(\.name)
        #expect(names.first == "report")
        // Prefix matches (shorter name first), then the word start, then the inner substring.
        #expect(names == ["report", "report.txt", "reports-2026", "old-report", "myreport"])
    }

    @Test func foldsCaseAndAccents() throws {
        let temp = try Self.tree()
        let index = try FolderNameIndex.build(root: temp.url)
        #expect(index.search("RESUME").map(\.relativePath) == ["Café/résumé.pdf"])
        #expect(index.search("cafe").map(\.relativePath) == ["Café"])
    }

    @Test func skipsHiddenAndPackageContentsLikeFinder() throws {
        let temp = try Self.tree()
        let index = try FolderNameIndex.build(root: temp.url)
        let paths = index.search("report").map(\.relativePath)
        #expect(!paths.contains { $0.hasPrefix(".git") })
        #expect(!paths.contains { $0.hasPrefix("Tool.app/") })
        // The package itself is a result.
        #expect(index.search("tool").map(\.relativePath) == ["Tool.app"])
        let hidden = try FolderNameIndex.build(root: temp.url, includeHidden: true)
        #expect(hidden.search("report-hidden").map(\.relativePath) == [".git/report-hidden"])
    }

    @Test func capsResultsAndCountsEntries() throws {
        let temp = try TempFolder()
        for i in 0..<300 { try temp.file("file-\(i).txt") }
        let index = try FolderNameIndex.build(root: temp.url)
        #expect(index.count == 300)
        #expect(index.search("file", limit: 50).count == 50)
        #expect(index.search("").isEmpty)
        #expect(index.search("nothing-like-this").isEmpty)
    }

    @Test func stopsAtTheEntryLimit() throws {
        let temp = try TempFolder()
        for i in 0..<20 { try temp.file("f\(i)") }
        let index = try FolderNameIndex.build(root: temp.url, entryLimit: 10)
        #expect(index.truncated)
        #expect(index.count == 10)
    }

    @Test func hitsCarryTheirURLAndKind() throws {
        let temp = try Self.tree()
        let index = try FolderNameIndex.build(root: temp.url)
        let hit = try #require(index.search("ReportView").first)
        #expect(hit.url == temp.url.appendingPathComponent("src/ui/ReportView.swift"))
        #expect(!hit.isDirectory)
        #expect(try #require(index.search("docs").first).isDirectory)
    }

    @Test func aMissingRootThrows() {
        #expect(throws: (any Error).self) {
            try FolderNameIndex.build(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        }
    }
}

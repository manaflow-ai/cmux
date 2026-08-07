import Foundation
import Testing
@testable import CmuxPanes

@Suite("Markdown panel file link resolver")
struct MarkdownPanelFileLinkResolverTests {
    @Test("Relative links prefer the containing file and retain an injected fallback root")
    func relativeLinkResolutionOrder() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "cmux-panes-markdown-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        let docs = root.appending(path: "docs", directoryHint: .isDirectory)
        let sourceFile = docs.appending(path: "index.md")
        let adjacentFile = docs.appending(path: "plan.md")
        let fallbackFile = root.appending(path: "fallback.md")

        try fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Adjacent".write(to: adjacentFile, atomically: true, encoding: .utf8)
        try "# Fallback".write(to: fallbackFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let resolver = MarkdownPanelFileLinkResolver(
            fileManager: fileManager,
            fallbackDirectoryPath: root.path
        )

        #expect(resolver.resolve(
            rawPath: "plan.md",
            relativeToMarkdownFile: sourceFile.path
        ) == adjacentFile.path)
        #expect(resolver.resolve(
            rawPath: "fallback.md",
            relativeToMarkdownFile: sourceFile.path
        ) == fallbackFile.path)
    }

    @Test("Only authored local path forms can resolve to local Markdown files")
    func authoredLocalPathClassification() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "cmux-panes-markdown-schemes-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceFile = root.appending(path: "index.md")
        let colonFile = root.appending(path: "chapter:one.md")
        let remoteLookalike = root.appending(path: "raw/plan.md")

        try fileManager.createDirectory(
            at: remoteLookalike.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "# Chapter".write(to: colonFile, atomically: true, encoding: .utf8)
        try "# Local lookalike".write(to: remoteLookalike, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let resolver = MarkdownPanelFileLinkResolver(
            fileManager: fileManager,
            fallbackDirectoryPath: root.path
        )

        #expect(resolver.resolve(
            rawPath: "./chapter:one.md",
            relativeToMarkdownFile: sourceFile.path
        ) == colonFile.path)
        #expect(resolver.resolve(
            rawPath: "https://raw/plan.md",
            relativeToMarkdownFile: sourceFile.path
        ) == nil)
        #expect(resolver.resolve(
            rawPath: "obsidian:chapter.md",
            relativeToMarkdownFile: sourceFile.path
        ) == nil)
    }

    @Test("Non-Markdown files resolve only through the local-file API")
    func nonMarkdownLocalFile() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "cmux-panes-local-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceFile = root.appending(path: "index.md")
        let textFile = root.appending(path: "notes.txt")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Index".write(to: sourceFile, atomically: true, encoding: .utf8)
        try "Notes".write(to: textFile, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let resolver = MarkdownPanelFileLinkResolver(
            fileManager: fileManager,
            fallbackDirectoryPath: root.path
        )

        #expect(resolver.resolveLocalFile(
            rawPath: "notes.txt",
            relativeToMarkdownFile: sourceFile.path
        ) == textFile.path)
        #expect(resolver.resolve(
            rawPath: "notes.txt",
            relativeToMarkdownFile: sourceFile.path
        ) == nil)
    }
}

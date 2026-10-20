import CmuxNextTerminalLinks
import Foundation
import Testing

/// What a Cmd-clicked terminal link resolves to (cx-do47).
struct TerminalLinkResolverTests {
    private let resolver = TerminalLinkResolver()
    private let tlds: (String) -> Bool = { ["com", "rs"].contains($0) }

    @Test func aSchemeIsAURL() {
        #expect(resolver.resolve("https://example.com/a", cwd: nil) == .url(URL(string: "https://example.com/a")!))
    }

    @Test func quotesAndTrailingPunctuationGo() {
        #expect(resolver.resolve("\"https://example.com/a\",", cwd: nil) == .url(URL(string: "https://example.com/a")!))
        #expect(resolver.resolve("(https://en.wikipedia.org/wiki/Foo_(bar))", cwd: nil)
            == .url(URL(string: "https://en.wikipedia.org/wiki/Foo_(bar)")!))
    }

    @Test func aWebHostWithoutASchemeNeedsARealDomain() {
        #expect(resolver.resolve("localhost:3000/docs", cwd: nil, isTopLevelDomain: tlds) == .url(URL(string: "http://localhost:3000/docs")!))
        #expect(resolver.resolve("docs.rs/serde", cwd: nil, isTopLevelDomain: tlds) == .url(URL(string: "https://docs.rs/serde")!))
        #expect(resolver.resolve("build-fleet/x.md", cwd: nil, isTopLevelDomain: tlds) == nil)
    }

    @Test func aRelativePathResolvesUnderTheTerminalsFolderWithoutItsLocation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("src/app.ts")
        try Data().write(to: file)

        guard case .file(let url, isDirectory: false)? = resolver.resolve("src/app.ts:3:5", cwd: folder.path) else {
            Issue.record("src/app.ts:3:5 did not resolve to the file")
            return
        }
        #expect(url.standardizedFileURL.path == file.standardizedFileURL.path)
        #expect(resolver.resolve("src/missing.ts", cwd: folder.path, isTopLevelDomain: tlds) == nil)
    }
}

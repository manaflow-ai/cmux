import Foundation
import Testing

@testable import CmuxFileSearch

enum InstalledRipgrep {
    static let path: String? = [
        "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Runs the real ripgrep over a scratch tree, so the option mapping is
/// proven by what ripgrep actually returns rather than by the argv shape.
@Suite("ripgrep end to end", .serialized, .enabled(if: InstalledRipgrep.path != nil, "needs ripgrep"))
struct RipgrepIntegrationTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-file-search-\(UUID().uuidString)")
        let files: [String: String] = [
            "src/app.swift": "let Needle = 1\nlet needle = 2\nneedles are sharp\n",
            "src/app.test.swift": "needle in test\n",
            "docs/readme.md": "a needle in docs\n",
            "node_modules/dep/index.js": "needle in dependency\n",
            "ignored/secret.txt": "needle ignored by gitignore\n",
            ".gitignore": "ignored/\n",
            ".env": "needle=hidden file\n",
            ".git/config": "needle inside git\n",
        ]
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        // ripgrep honors .gitignore only inside a repository.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
    }

    private func search(_ query: FileSearchQuery) async throws -> (files: [String: Int], completion: FileSearchCompletion) {
        let rg = try #require(InstalledRipgrep.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let mailbox = FileSearchBatchMailbox()
        let completion = await RipgrepStreamingSearch(command: FileSearchCommand(executablePath: rg, arguments: query.ripgrepArguments(rootPath: root.path)), matchLimit: 1_000).run(sink: mailbox)
        var counts: [String: Int] = [:]
        for group in mailbox.drain().groups {
            counts[String(group.path.dropFirst(root.path.count + 1)), default: 0] += group.matches.count
        }
        return (counts, completion)
    }

    @Test("Defaults: case-insensitive literal, hidden files, ignore rules, never .git")
    func defaults() async throws {
        let result = try await search(FileSearchQuery(pattern: "needle"))
        #expect(result.completion == .completed)
        #expect(result.files == ["src/app.swift": 3, "src/app.test.swift": 1, "docs/readme.md": 1, ".env": 1])
    }

    @Test("Match Case")
    func matchCase() async throws {
        let result = try await search(FileSearchQuery(pattern: "Needle", isCaseSensitive: true))
        #expect(result.files == ["src/app.swift": 1])
    }

    @Test("Match Whole Word")
    func wholeWord() async throws {
        let result = try await search(FileSearchQuery(pattern: "needle", isCaseSensitive: true, matchesWholeWord: true, includePatterns: "src"))
        #expect(result.files == ["src/app.swift": 1, "src/app.test.swift": 1])
    }

    @Test("Regex with an invalid pattern reports ripgrep's parse error")
    func invalidRegex() async throws {
        let result = try await search(FileSearchQuery(pattern: "needle(", isRegex: true))
        guard case .failed(.invalidRegex(let detail)) = result.completion else {
            Issue.record("expected invalidRegex, got \(result.completion)")
            return
        }
        #expect(detail?.isEmpty == false)
    }

    @Test("Include and exclude globs")
    func globs() async throws {
        let result = try await search(FileSearchQuery(pattern: "needle", includePatterns: "src", excludePatterns: "*.test.swift"))
        #expect(result.files == ["src/app.swift": 3])
    }

    @Test("Turning off ignore files finds ignored and generated folders")
    func ignoreFilesOff() async throws {
        let result = try await search(FileSearchQuery(pattern: "needle", usesIgnoreFiles: false))
        #expect(result.files["ignored/secret.txt"] == 1)
        #expect(result.files["node_modules/dep/index.js"] == 1)
        #expect(result.files[".git/config"] == nil)
    }

    @Test("A non-ASCII pattern matches NFC file contents")
    func unicodePattern() async throws {
        let url = root.appendingPathComponent("unicode.txt")
        try "caf\u{E9} au lait\n".write(to: url, atomically: true, encoding: .utf8)
        let result = try await search(FileSearchQuery(pattern: "caf\u{E9}"))
        #expect(result.files["unicode.txt"] == 1)
    }
}

import CmuxFoundation
import Foundation
import Testing

@testable import CmuxCommandPalette

struct GoToFileSearchTests {
    @Test
    func rankingPrefersFilenameMatches() {
        let paths = ["Sources/Workspace.swift", "Sources/WorkspaceTests.swift", "docs/workspaces.md"]
        #expect(GoToFileSearchService.rank(paths: paths, query: "workspace", limit: 3).first == paths[0])
    }

    @Test
    func listingRespectsGitExcludesAndWorkspaceRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".gitignore", "*.log\nignored/\n")
        try fixture.write("outside.txt")
        try fixture.write("nested/tracked.log")
        try fixture.write("nested/visible.txt")
        try fixture.write("nested/ignored.log")
        try fixture.write("nested/ignored/file.txt")
        try await fixture.git(["init"])
        try await fixture.git(["add", "outside.txt", ".gitignore"])
        try await fixture.git(["add", "-f", "nested/tracked.log"])
        let matches = await GoToFileSearchService().search(rootPath: fixture.root.appendingPathComponent("nested").path, query: "")
        #expect(Set(matches.map(\.path)) == ["tracked.log", "visible.txt"])
    }

    @Test(.timeLimit(.minutes(1)))
    func largeListingDrainsAllOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.git(["init"])
        let paths = (0..<3_000).map { String(format: "file-%04d-", $0) + String(repeating: "x", count: 80) + ".txt" }
        for path in paths { try fixture.write(path) }
        try await fixture.git(["add", "."])
        let matches = await GoToFileSearchService(maximumResults: paths.count).search(rootPath: fixture.root.path, query: "")
        #expect(Set(matches.map(\.path)) == Set(paths))
    }

    @Test
    func fallbackPreservesNullSeparatedNames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("listing.sh", "printf 'line\\nbreak.txt\\000ordinary.txt\\000'\n")
        let matches = await GoToFileSearchService(
            ripgrepExecutable: "/bin/sh",
            ripgrepPrefixArguments: [fixture.root.appendingPathComponent("listing.sh").path]
        ).search(rootPath: fixture.root.path, query: "")
        #expect(Set(matches.map(\.path)) == ["line\nbreak.txt", "ordinary.txt"])
    }

    private struct Fixture: Sendable {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("go-to-file-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ path: String, _ text: String = "fixture") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func git(_ arguments: [String]) async throws {
            let result = await CommandRunner().run(directory: root.path, executable: "/usr/bin/git", arguments: arguments, timeout: 30)
            try #require(result.executionError == nil)
            try #require(result.exitStatus == 0)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

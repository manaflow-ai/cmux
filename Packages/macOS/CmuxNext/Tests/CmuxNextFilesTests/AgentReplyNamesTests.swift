import Foundation
import Testing
@testable import CmuxNextFiles

/// The App's search for a bare file name a reply wrote: exact names only, files only, never
/// inside hidden or generated folders, best first by depth below its own root, and never a walk
/// of the home folder.
@MainActor
struct AgentReplyNamesTests {
    @Test func findsFilesOfExactlyThatNameBestFirst() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reply-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        // Two roots of different depth: a file right in the deeper root beats one a folder down
        // in the shallow root, because depth counts below each file's own root.
        let shallow = base.appendingPathComponent("a"), deep = base.appendingPathComponent("a-deep/b/c/d")
        for folder in ["a/x", "a/.git/hooks", "a/node_modules/pkg", "a/next-sync.py.d", "a-deep/b/c/d"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["a/x/next-sync.py", "a-deep/b/c/d/next-sync.py", "a/x/next-sync.pyc", "a/.git/hooks/next-sync.py",
                     "a/node_modules/pkg/next-sync.py"] {
            try Data("x".utf8).write(to: base.appendingPathComponent(file))
        }
        let names = AgentReplyNames(home: "/nonexistent-home-\(UUID().uuidString)")
        let found = await names.find(["next-sync.py", "missing.py"], in: [shallow.path, deep.path])
        // The temporary folder may come back as /private/var or /var: compare the ends.
        let paths = found["next-sync.py"] ?? []
        #expect(paths.count == 2)
        #expect(paths.first?.hasSuffix("/a-deep/b/c/d/next-sync.py") == true)
        #expect(paths.last?.hasSuffix("/a/x/next-sync.py") == true)
        #expect(!paths.contains { $0.contains("/.git/") || $0.contains("/node_modules/") })
        #expect(found["missing.py"]?.isEmpty ?? true)
    }

    /// More matches than are returned: the shallowest still wins, even with a long folder name.
    @Test func theCutComesAfterRankingAcrossAllMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reply-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var files = ["a-very-long-folder-name-that-sorts-late/README.md"]
        for i in 0..<30 { files.append("d\(i)/e/f/README.md") }
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let found = await AgentReplyNames(home: "/nonexistent-home-\(UUID().uuidString)").find(["README.md"], in: [root.path])
        let paths = found["README.md"] ?? []
        #expect(paths.count == AgentReplyNames.hitsPerName)
        #expect(paths.first?.hasSuffix("/a-very-long-folder-name-that-sorts-late/README.md") == true)
    }

    @Test(arguments: [("/", true), ("/Users/me", true), ("/Users", true), ("/Users/me/project", false), ("/tmp/x", false)])
    func theHomeFolderAndAboveAreNeverWalked(root: String, broad: Bool) {
        #expect(AgentReplyNames.isTooBroad(root, home: "/Users/me") == broad)
    }

    @Test func rankingCountsFoldersBelowEachRoot() {
        let ranked = AgentReplyNames.ranked([
            ("outputs/2026-10-21/build.py", "/r/outputs/2026-10-21/build.py"),
            ("scripts/build.py", "/r/scripts/build.py"),
            ("build.py", "/very/deep/other/root/build.py"),
            ("a/build.py", "/r/a/build.py"),
        ]).map(\.path)
        #expect(ranked == ["/very/deep/other/root/build.py", "/r/a/build.py", "/r/scripts/build.py", "/r/outputs/2026-10-21/build.py"])
    }
}

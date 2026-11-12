import CmuxDiffComments
import Foundation
import Testing

@Suite struct DiffViewerOpenableFileTests {
    /// A temp directory holding `repo/` (a work tree with `.git/config`,
    /// `src/a.txt`, links in and out) and `outside.txt` beside it.
    private func makeRepo() throws -> (base: URL, repo: String) {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("diff-open-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try manager.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repo.appendingPathComponent(".git/config"))
        try Data("a".utf8).write(to: repo.appendingPathComponent("src/a.txt"))
        try Data("o".utf8).write(to: base.appendingPathComponent("outside.txt"))
        try manager.createSymbolicLink(atPath: repo.appendingPathComponent("out-link").path, withDestinationPath: "../outside.txt")
        try manager.createSymbolicLink(atPath: repo.appendingPathComponent("in-link").path, withDestinationPath: "src/a.txt")
        try manager.createSymbolicLink(atPath: repo.appendingPathComponent("git-link").path, withDestinationPath: ".git/config")
        return (base, repo.path)
    }

    @Test func opensRegularFilesInsideTheRepository() throws {
        let (base, repo) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try #require(diffViewerOpenableFileURL(repoRoot: repo, path: "src/a.txt"))
        #expect(file.lastPathComponent == "a.txt")
        #expect(diffViewerOpenableFileURL(repoRoot: repo, path: "in-link")?.lastPathComponent == "a.txt")
    }

    @Test(arguments: ["../outside.txt", "src/../../outside.txt", "out-link", ".git/config", ".GIT/config", "git-link", "src", "missing.txt", "", "/etc/hosts"])
    func refuses(path: String) throws {
        let (base, repo) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(diffViewerOpenableFileURL(repoRoot: repo, path: path) == nil)
    }

    @Test func refusesARootThatIsNotAWorkTree() throws {
        let (base, _) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(diffViewerOpenableFileURL(repoRoot: base.path, path: "outside.txt") == nil)
    }
}

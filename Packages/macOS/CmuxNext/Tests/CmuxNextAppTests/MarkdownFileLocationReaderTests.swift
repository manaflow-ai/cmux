@testable import CmuxNextApp
import Foundation
import Testing

/// The Markdown omnibar reads a file's location through real git (design section 3): a temporary
/// repository with a bare `origin` on GitHub's URL shape (rewritten to the local bare repository
/// with `url.<base>.insteadOf`), then the file pushed, committed but not pushed, edited, untracked;
/// and a file in no repository.
@Suite(.serialized) struct MarkdownFileLocationReaderTests {
    private let root: URL
    private let work: URL
    private let home: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "md-loc-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        work = root.appending(path: "repo", directoryHint: .isDirectory)
        home = root.path
        let bare = root.appending(path: "origin.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "--bare", bare.path], in: root)
        try Self.git(["init", "-q", "-b", "main"], in: work)
        try Self.git(["config", "user.email", "t@example.com"], in: work)
        try Self.git(["config", "user.name", "T"], in: work)
        try Self.git(["config", "commit.gpgsign", "false"], in: work)
        try Self.git(["config", "url.\(bare.path).insteadOf", "https://github.com/acme/notes.git"], in: work)
        try Self.git(["remote", "add", "origin", "https://github.com/acme/notes.git"], in: work)
        try Data("# Readme\n".utf8).write(to: work.appending(path: "README.md"))
        try Self.git(["add", "README.md"], in: work)
        try Self.git(["commit", "-q", "-m", "first"], in: work)
        try Self.git(["push", "-q", "-u", "origin", "main"], in: work)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private static func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.standardOutput = output
        process.standardError = output
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1"]
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw GitFailed(message: text) }
        return text
    }

    private struct GitFailed: Error { let message: String }

    private func read(_ name: String) async -> MarkdownFileLocation {
        await MarkdownFileLocationReader(home: home).read(work.appending(path: name))
    }

    @Test func aPushedCleanFileIsPushedWithItsExactLink() async throws {
        defer { cleanUp() }
        let location = await read("README.md")
        #expect(location.displayPath == "~/repo/README.md")
        let git = try #require(location.git)
        #expect(git.root == work.path)
        #expect(git.relativePath == "README.md")
        #expect(git.branch == "main")
        #expect(git.upstream == "origin/main")
        #expect(git.githubRepository == "acme/notes")
        #expect(git.state == .pushed)
        #expect(git.blobURL?.absoluteString == "https://github.com/acme/notes/blob/main/README.md")
    }

    @Test func aCommittedButNotPushedChangeIsUnpushed() async throws {
        defer { cleanUp() }
        try Data("# Readme\nmore\n".utf8).write(to: work.appending(path: "README.md"))
        try Self.git(["commit", "-q", "-am", "second"], in: work)
        let git = try #require(await read("README.md").git)
        #expect(git.state == .unpushed)
        #expect(git.ahead == 1)
    }

    @Test func aFileUnchangedSinceThePushIsPushedEvenWhenTheBranchIsAhead() async throws {
        defer { cleanUp() }
        try Data("other\n".utf8).write(to: work.appending(path: "other.md"))
        try Self.git(["add", "other.md"], in: work)
        try Self.git(["commit", "-q", "-m", "other"], in: work)
        let git = try #require(await read("README.md").git)
        #expect(git.ahead == 1)
        #expect(git.state == .pushed)
    }

    @Test func anEditedFileIsModifiedAndANewOneUntracked() async throws {
        defer { cleanUp() }
        try Data("# Readme\nedit\n".utf8).write(to: work.appending(path: "README.md"))
        try Data("new\n".utf8).write(to: work.appending(path: "NEW.md"))
        #expect(await read("README.md").git?.state == .modified)
        #expect(await read("NEW.md").git?.state == .untracked)
    }

    @Test func aFileInNoRepositoryHasNoGit() async throws {
        defer { cleanUp() }
        let loose = root.appending(path: "loose", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: loose.appending(path: "notes.md"))
        let location = await MarkdownFileLocationReader(home: home).read(loose.appending(path: "notes.md"))
        #expect(location.git == nil)
        #expect(location.displayPath == "~/loose/notes.md")
    }
}

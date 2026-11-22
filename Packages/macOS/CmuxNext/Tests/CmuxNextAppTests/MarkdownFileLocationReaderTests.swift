@testable import CmuxNextApp
import Foundation
import CmuxNextCompat
import Testing

/// The Markdown omnibar reads a file's location through real git (design section 3): a temporary
/// repository with a bare `origin` on GitHub's URL shape (rewritten to the local bare repository
/// with `url.<base>.insteadOf`), then the file pushed, committed but not pushed, edited, untracked;
/// and a file in no repository.
@Suite(.serialized) struct MarkdownFileLocationReaderTests {
    private let root: URL
    private let work: URL
    private let home: String

    /// Each test changes its work tree, so each gets its own copy of one pushed repository, which the
    /// suite builds once with real git (nine commands and a push). The copy is a file copy: no process.
    init() throws {
        let template = try Self.template.get()
        root = FileManager.default.temporaryDirectory.appending(path: "md-loc-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        work = root.appending(path: "repo", directoryHint: .isDirectory)
        home = root.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: template.appending(path: "repo", directoryHint: .isDirectory), to: work)
    }

    /// The pushed repository every test copies: `repo` with `README.md` committed and pushed to `origin.git`,
    /// its bare `origin` on GitHub's URL shape. The reader's git commands are read-only, so the copies never
    /// write to this `origin`. Removed when the test process exits.
    private static let template = Result { () throws -> URL in
        let root = FileManager.default.temporaryDirectory.appending(path: "md-loc-template-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let work = root.appending(path: "repo", directoryHint: .isDirectory)
        let bare = root.appending(path: "origin.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try MarkdownFileLocationReaderTests.git(["init", "-q", "--bare", bare.path], in: root)
        try MarkdownFileLocationReaderTests.git(["init", "-q", "-b", "main"], in: work)
        try MarkdownFileLocationReaderTests.git(["config", "user.email", "t@example.com"], in: work)
        try MarkdownFileLocationReaderTests.git(["config", "user.name", "T"], in: work)
        try MarkdownFileLocationReaderTests.git(["config", "commit.gpgsign", "false"], in: work)
        try MarkdownFileLocationReaderTests.git(["config", "url.\(bare.path).insteadOf", "https://github.com/acme/notes.git"], in: work)
        try MarkdownFileLocationReaderTests.git(["remote", "add", "origin", "https://github.com/acme/notes.git"], in: work)
        try Data("# Readme\n".utf8).write(to: work.appending(path: "README.md"))
        try MarkdownFileLocationReaderTests.git(["add", "README.md"], in: work)
        try MarkdownFileLocationReaderTests.git(["commit", "-q", "-m", "first"], in: work)
        try MarkdownFileLocationReaderTests.git(["push", "-q", "-u", "origin", "main"], in: work)
        MarkdownFileLocationReaderTests.templatePath.withLock { $0 = root.path }
        atexit { MarkdownFileLocationReaderTests.templatePath.withLock { path in if let path { try? FileManager.default.removeItem(atPath: path) } } }
        return root
    }

    /// The template's folder, for the exit handler (a C function pointer captures nothing).
    private nonisolated static let templatePath = Mutex<String?>(nil)

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

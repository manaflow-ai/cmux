@testable import CmuxNextApp
import CmuxNextFiles
import CmuxNextFilesUI
import CmuxNextPages
import Foundation
import Testing

/// LAUNCH-NO-TCC-PROMPTS: the Files section roots itself at the focused terminal's folder with no
/// action from the person (a launch that restores the sidebar open, a `cd`). In a
/// privacy-protected folder (~/Downloads) it lists nothing and watches nothing until the person
/// asks (its Show Contents button); listing there would make macOS ask in cmux's name.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FileExplorerProtectedFolderTests {
    /// Counts the folders it was asked to list; lists the real disk.
    final class CountingLister: DirectoryListing, @unchecked Sendable {
        // Read and written on the main actor only (the model's calls), in this test.
        nonisolated(unsafe) var listed: [URL] = []
        let real = DirectoryLister()
        func list(_ folder: URL) async throws -> [FileEntry] {
            listed.append(folder.standardizedFileURL)
            return try await real.list(folder)
        }
        func entry(at url: URL) async -> FileEntry? { await real.entry(at: url) }
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("a.txt"))
        return url.standardizedFileURL
    }

    @Test func aProtectedFolderIsNotListedUntilThePersonAsks() async throws {
        let guarded = try Self.folder(), plain = try Self.folder()
        let lister = CountingLister()
        let model = FileExplorerModel(lister: lister, isProtected: { $0.standardizedFileURL == guarded })
        await model.setRoot(guarded)
        #expect(model.root == guarded)
        #expect(model.held)
        #expect(model.rows.isEmpty)
        #expect(lister.listed.isEmpty, "listed a protected folder unasked: \(lister.listed)")
        // A watcher's reload lists nothing either.
        await model.reload()
        #expect(lister.listed.isEmpty)

        // The person asks: it lists, and later automatic roots there list too.
        await model.setRoot(guarded, asked: true)
        #expect(!model.held)
        #expect(model.rows.map(\.name) == ["a.txt"])
        await model.setRoot(plain)
        await model.setRoot(guarded)
        #expect(!model.held)

        // An ordinary folder lists at once.
        await model.setRoot(plain)
        #expect(!model.held)
        #expect(lister.listed.contains(plain))
    }

    static func git(_ folder: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "-c", "user.name=t", "-c", "user.email=t@e.test", "-c", "commit.gpgsign=false",
                             "-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { _, ours in ours }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments) in \(folder.path)")
    }

    /// A home folder kept in git (a dotfiles `~/.git`): every file the repository does not track
    /// is one of its untracked files, the Photos library and Desktop included, so listing them
    /// reads every folder of the home folder in cmux's name. The Files tree's status read of that
    /// repository (``FileGitState/statusArguments(top:home:)``, run by real git) shows its tracked
    /// change and no untracked file; a repository of its own below the home folder still lists its
    /// untracked files.
    @Test func theHomeFoldersRepositoryListsNoUntrackedFiles() async throws {
        let home = try Self.folder()
        try Self.git(home, "init", "--quiet")
        try Self.git(home, "add", "a.txt")
        try Self.git(home, "commit", "--quiet", "-m", "dotfiles")
        try Data("changed".utf8).write(to: home.appendingPathComponent("a.txt"))
        let photos = home.appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("p".utf8).write(to: photos.appendingPathComponent("Photos.sqlite"))
        let app = home.appendingPathComponent("code/app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Self.git(app, "init", "--quiet")
        try Data("new".utf8).write(to: app.appendingPathComponent("new.rs"))
        defer { try? FileManager.default.removeItem(at: home) }
        let git = ProcessMarkdownGitRunner()
        let states = { (top: URL) async -> [String: FileGitState] in
            let arguments = FileGitState.statusArguments(top: top.path, home: home.path)
            let output = await git.run(arguments, in: top.path)
            #expect(output?.status == 0, "git \(arguments)")
            return FileGitState.parse(output?.output ?? "")
        }

        #expect(FileGitState.statusArguments(top: home.path, home: home.path).last == "--untracked-files=no")
        #expect(await states(home) == ["a.txt": .modified], "the tracked change only")
        #expect(FileGitState.statusArguments(top: app.path, home: home.path).last == "--untracked-files=all")
        #expect(await states(app) == ["new.rs": .untracked], "a repository of its own lists its new file")
        // Another home folder: the repository lists its untracked files as before.
        let listed = await git.run(FileGitState.statusArguments(top: home.path, home: app.path), in: home.path)
        #expect(FileGitState.parse(listed?.output ?? "").keys.contains { $0.hasPrefix("Pictures/") })
    }

    @Test func theDefaultCheckKnowsDownloadsByItsSpelling() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FileExplorerModel.inProtectedFolder(home.appendingPathComponent("Downloads/project")))
        #expect(FileExplorerModel.inProtectedFolder(home.appendingPathComponent("Desktop")))
        #expect(!FileExplorerModel.inProtectedFolder(home.appendingPathComponent("code/cmux")))
        #expect(!FileExplorerModel.inProtectedFolder(FileManager.default.temporaryDirectory))
    }
}

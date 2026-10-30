import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import Foundation
import Testing
import CmuxNextFilesUI

/// The Files tree and its git states follow changes made outside cmux (an editor, an agent, a
/// `git add` in a terminal): a file-system watch on the tree's folder and the repository's
/// index lists the tree again. Nothing polls.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FileExplorerWatchTests {
    /// A watch the test fires by hand, recording what it was asked to watch.
    @MainActor final class ManualWatch: FileTreeWatching {
        private(set) var watched: [[URL]] = []
        private var continuations: [AsyncStream<Void>.Continuation] = []
        nonisolated func changes(under folders: [URL]) -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            MainActor.assumeIsolated {
                watched.append(folders)
                continuations.append(continuation)
            }
            return stream
        }
        func fire() { continuations.last?.yield() }
    }

    /// `git` whose status answer the test changes.
    final class ChangingGit: MarkdownGitRunning, @unchecked Sendable {
        let top: String
        var porcelain = ""
        init(top: String) { self.top = top }
        func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
            switch arguments.first {
            case "rev-parse": MarkdownGitOutput(status: 0, output: top + "\n")
            case "status": MarkdownGitOutput(status: 0, output: porcelain)
            default: nil
            }
        }
    }

    @Test func aChangeOutsideCmuxListsTheTreeAndItsGitStatesAgain() async throws {
        let root = try FileExplorerTests.folder()
        let git = ChangingGit(top: root.resolvingSymlinksInPath().path)
        let watch = ManualWatch()
        let model = FileExplorerModel(git: git, watcher: watch)
        await model.setRoot(root)
        let watched = try #require(watch.watched.last)
        #expect(watched.contains(root.standardizedFileURL), "the tree's folder is not watched")
        #expect(watched.contains { $0.lastPathComponent == ".git" }, "the repository's git folder is not watched")
        // An editor adds a file and git sees it as new.
        try Data("x".utf8).write(to: root.appendingPathComponent("new.txt"))
        git.porcelain = "?? new.txt\0"
        watch.fire()
        for await rows in ObservationStream({ model.rows }) where rows.contains(where: { $0.name == "new.txt" && $0.git == .untracked }) { break }
    }

    /// The App's watch reports a file made in the folder (FSEvents, no polling).
    @Test func theFileSystemWatchReportsAFileMadeInTheFolder() async throws {
        let root = try FileExplorerTests.folder()
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let changes = FileTreeWatcher(latency: 0.05, started: { didStart.yield() }).changes(under: [root])
        var iterator = changes.makeAsyncIterator()
        // The watch reports changes made after its FSEvents stream started: wait for that signal.
        for await _ in started { break }
        try Data("x".utf8).write(to: root.appendingPathComponent("made.txt"))
        let next: Void? = await iterator.next()
        #expect(next != nil)
    }
}

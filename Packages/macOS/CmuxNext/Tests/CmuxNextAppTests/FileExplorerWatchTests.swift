import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextFiles
import CmuxNextWakeups
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
        /// Sends one change to the newest watch; false when that watch has ended.
        @discardableResult
        func fire() -> Bool {
            guard let result = continuations.last?.yield() else { return false }
            if case .terminated = result { return false }
            return true
        }
    }

    /// Counts the listings of the tree's root, listing the real folder.
    nonisolated struct CountingLister: DirectoryListing {
        actor Count {
            private(set) var value = 0
            func add() { value += 1 }
        }
        let root: URL
        let count = Count()
        func list(_ folder: URL) async throws -> [FileEntry] {
            if folder.standardizedFileURL == root.standardizedFileURL { await count.add() }
            return try await DirectoryLister().list(folder)
        }
        func entry(at url: URL) async -> FileEntry? { await DirectoryLister().entry(at: url) }
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

    /// p14-energy-127: a tree no surface shows stops its watch, so 100 writes by another app wake it 0 times, and
    /// its next show lists it once and watches again.
    @Test func aHiddenTreeStopsWatchingAndListsOnceOnShow() async throws {
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        let model = FileExplorerModel(lister: lister, git: ChangingGit(top: root.resolvingSymlinksInPath().path), watcher: watch)
        await model.setRoot(root)
        #expect(await lister.count.value == 1)
        #expect(watch.watched.count == 1)

        model.setShown(false)
        // An agent writes the folder 100 times while the tree is hidden: none of it reaches the model.
        for index in 0..<100 {
            try Data("\(index)".utf8).write(to: root.appendingPathComponent("agent-\(index).txt"))
            watch.fire()
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!watch.fire(), "the hidden tree's watch did not end")
        #expect(await lister.count.value == 1, "the hidden tree listed itself again")
        #expect(model.catchUp == nil)

        model.setShown(true)
        await model.catchUp?.value
        #expect(await lister.count.value == 2, "the show did not list the tree once")
        #expect(watch.watched.count == 2, "the show did not watch the tree again")
        #expect(model.rows.contains(where: { $0.name == "agent-99.txt" }))
        // Shown again with nothing missed: no second listing.
        model.setShown(true)
        #expect(await lister.count.value == 2)
    }

    /// A tree rooted while hidden (the follow is a service) lists without watching, and catches up on show.
    @Test func aTreeRootedWhileHiddenWatchesOnlyOnceShown() async throws {
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        let model = FileExplorerModel(lister: lister, git: ChangingGit(top: root.resolvingSymlinksInPath().path), watcher: watch)
        model.setShown(false)
        await model.setRoot(root)
        #expect(await lister.count.value == 1)
        #expect(watch.watched.isEmpty, "a hidden tree started a watch")
        model.setShown(true)
        await model.catchUp?.value
        #expect(await lister.count.value == 2)
        #expect(watch.watched.count == 1)
    }

    /// Energy Saver coalesces the FSEvents stream 4 times longer; the policy is read when a stream starts.
    @Test func theWatchCoalescesFourTimesLongerInEnergySaver() {
        let energy = EnergyPolicySource()
        let watcher = FileTreeWatcher(latency: 0.2, energy: energy)
        #expect(watcher.currentLatency == 0.2)
        energy.update(EnergyPolicy(saverReason: .setting))
        #expect(watcher.currentLatency == 0.8)
        #expect(FileTreeWatcher(latency: 0.2).currentLatency == 0.2)
    }
}

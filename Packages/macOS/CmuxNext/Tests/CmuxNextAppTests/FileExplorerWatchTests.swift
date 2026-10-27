import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
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
        /// One value per watch started.
        let starts: AsyncStream<Void>
        private let started: AsyncStream<Void>.Continuation
        init() { (starts, started) = AsyncStream.makeStream(of: Void.self) }
        nonisolated func changes(under folders: [URL]) -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            MainActor.assumeIsolated {
                watched.append(folders)
                continuations.append(continuation)
                started.yield()
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

    /// Counts the listings of the tree's root, listing the real folder (or failing, as a folder gone for a moment).
    nonisolated struct CountingLister: DirectoryListing {
        actor Count {
            private(set) var value = 0
            private(set) var failing = false
            func add() { value += 1 }
            func fail(_ on: Bool) { failing = on }
        }
        struct Gone: Error {}
        let root: URL
        let count = Count()
        func list(_ folder: URL) async throws -> [FileEntry] {
            if folder.standardizedFileURL == root.standardizedFileURL {
                await count.add()
                if await count.failing { throw Gone() }
            }
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
        let changes = FileTreeWatcher(latency: 0.05, started: { _ in didStart.yield() }).changes(under: [root])
        var iterator = changes.makeAsyncIterator()
        // The watch reports changes made after its FSEvents stream started: wait for that signal.
        for await _ in started { break }
        try Data("x".utf8).write(to: root.appendingPathComponent("made.txt"))
        let next: Void? = await iterator.next()
        #expect(next != nil)
    }

    /// A model with `hiddenWatcherPause` on the counting lister and the manual watch.
    private static func pausingModel(_ root: URL, _ lister: CountingLister, _ watch: ManualWatch) -> FileExplorerModel {
        FileExplorerModel(lister: lister, git: ChangingGit(top: root.resolvingSymlinksInPath().path), watcher: watch,
                          pausesWhenHidden: true)
    }

    /// p14-energy-127: a tree no surface shows stops its watch, so 100 writes by another app wake it 0 times, and
    /// its next show lists it once and watches again.
    @Test func aHiddenTreeStopsWatchingAndListsOnceOnShow() async throws {
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        let model = Self.pausingModel(root, lister, watch)
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

    /// Without `hiddenWatcherPause` a hidden tree keeps its watch, as before the feature.
    @Test func withoutTheFeatureAHiddenTreeKeepsWatching() async throws {
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        let model = FileExplorerModel(lister: lister, git: ChangingGit(top: root.resolvingSymlinksInPath().path), watcher: watch)
        await model.setRoot(root)
        model.setShown(false)
        #expect(watch.fire(), "the hidden tree's watch ended with the feature off")
        model.setShown(true)
        #expect(model.catchUp == nil)
    }

    /// A tree rooted while hidden (the follow is a service) lists without watching, and catches up on show.
    @Test func aTreeRootedWhileHiddenWatchesOnlyOnceShown() async throws {
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        let model = Self.pausingModel(root, lister, watch)
        model.setShown(false)
        await model.setRoot(root)
        #expect(await lister.count.value == 1)
        #expect(watch.watched.isEmpty, "a hidden tree started a watch")
        model.setShown(true)
        await model.catchUp?.value
        #expect(await lister.count.value == 2)
        #expect(watch.watched.count == 1)
    }

    /// A catch-up that fails (the folder gone for a moment, a checkout) still watches the folder's path, and every
    /// later show catches up again, so the tree does not stay stale until a re-root.
    @Test func aFailedCatchUpStillCatchesUpOnTheNextShow() async throws {
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        let model = Self.pausingModel(root, lister, watch)
        await model.setRoot(root)
        model.setShown(false)
        await lister.count.fail(true)
        model.setShown(true)
        await model.catchUp?.value
        #expect(model.failure != nil)
        #expect(watch.watched.last == [root.standardizedFileURL], "a failed catch-up left the shown tree unwatched")

        model.setShown(false)
        await lister.count.fail(false)
        model.setShown(true)
        await model.catchUp?.value
        #expect(await lister.count.value == 3, "the show after a failed catch-up did not list the tree")
        #expect(model.failure == nil)
        #expect(!model.rows.isEmpty)
    }

    /// The Files section in a window, hidden and shown again as `showRightSidebar` shows it (the section unhides,
    /// then refreshes): one listing of the folder, and a new watch.
    @Test func aFilesSectionShownAgainListsItsFolderOnce() async throws {
        _ = NSApplication.shared
        let root = try FileExplorerTests.folder()
        let lister = CountingLister(root: root)
        let watch = ManualWatch()
        var starts = watch.starts.makeAsyncIterator()
        let model = Self.pausingModel(root, lister, watch)
        let section = FileExplorerSectionView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                              rootFolder: { root }, perform: { _ in }, rowMenu: { _ in nil })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The window's node reads visible (it is never ordered in), so the section follows only its own hide.
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = section
        defer { window.close() }
        // Made and shown: the section's refresh lists once and watches.
        _ = await starts.next()
        #expect(await lister.count.value == 1)

        section.isHidden = true
        #expect(!watch.fire(), "the hidden section's tree kept its watch")
        try Data("x".utf8).write(to: root.appendingPathComponent("agent.txt"))

        section.isHidden = false
        section.refresh()
        _ = await starts.next()
        await model.catchUp?.value
        for _ in 0..<10 { await Task.yield() }
        #expect(await lister.count.value == 2, "one show of the section listed its folder more than once")
        #expect(watch.watched.count == 2)
        #expect(model.rows.contains(where: { $0.name == "agent.txt" }))
    }

    /// Energy Saver coalesces the FSEvents stream 4 times longer.
    @Test func theWatchCoalescesFourTimesLongerInEnergySaver() {
        let energy = EnergyPolicySource()
        let watcher = FileTreeWatcher(latency: 0.2, energy: energy)
        #expect(watcher.currentLatency == 0.2)
        energy.update(EnergyPolicy(saverReason: .setting))
        #expect(watcher.currentLatency == 0.8)
        #expect(FileTreeWatcher(latency: 0.2).currentLatency == 0.2)
    }

    /// A running watch follows Energy Saver: when it turns on, the FSEvents stream starts again with the stretched
    /// latency (no re-root), yields once for the moment between the two streams, and still reports changes.
    @Test func aRunningWatchTakesTheSaverLatencyWithoutAReRoot() async throws {
        let root = try FileExplorerTests.folder()
        let energy = EnergyPolicySource()
        let (started, didStart) = AsyncStream.makeStream(of: CFTimeInterval.self)
        let changes = FileTreeWatcher(latency: 0.05, energy: energy, started: { didStart.yield($0) }).changes(under: [root])
        var iterator = changes.makeAsyncIterator()
        var starts = started.makeAsyncIterator()
        #expect(await starts.next() == 0.05)

        energy.update(EnergyPolicy(saverReason: .setting))
        #expect(await starts.next() == 0.2, "the running stream kept its latency under the saver")
        let gap: Void? = await iterator.next()
        #expect(gap != nil, "the new stream did not cover the moment between the two")

        try Data("x".utf8).write(to: root.appendingPathComponent("made.txt"))
        let next: Void? = await iterator.next()
        #expect(next != nil, "the stream made again reported no change")
    }
}


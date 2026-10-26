import CmuxNextWakeups
import Dispatch
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextFiles

/// p02-threads 047-052: the Files pane's file calls run on BackgroundWork lanes (Chrome's `MayBlock`
/// ThreadPool tasks, base/task/task_traits.h), never on a cooperative pool thread: short calls on `.files`,
/// calls whose length grows with their input on `.bulkFiles`, which never holds the serial files slot. Each test
/// counts the lane items its calls ran through the lanes' `onRan` hook.
@Suite(.timeLimit(.minutes(1))) struct FileOperatorLaneTests {
    /// One lane item `work` ran.
    struct Run: Sendable {
        let lane: BlockingLane
        let priority: WorkPriority
    }

    /// The lane and priority of every item `work` ran, recorded on its lane thread.
    final class Runs: Sendable {
        private let ran = Mutex<[Run]>([])
        private let reported: AsyncStream<Void>
        private let report: AsyncStream<Void>.Continuation

        init() {
            (reported, report) = AsyncStream.makeStream(of: Void.self)
        }

        func record(_ lane: BlockingLane, _ priority: WorkPriority) {
            ran.withLock { $0.append(Run(lane: lane, priority: priority)) }
            report.yield()
        }

        /// Returns once `count` items reported. A lane reports an item after its work ran, so the awaited call
        /// can return before its item reported: a test waits here instead of reading the count once.
        func wait(for count: Int) async {
            if total >= count { return }
            for await _ in reported where total >= count { return }
        }

        private var total: Int { ran.withLock { $0.count } }

        /// The items that ran on `lane` (at the caller's priority or above; `run` boosts an item to it).
        func runs(on lane: BlockingLane) -> [Run] {
            ran.withLock { $0.filter { $0.lane == lane } }
        }
    }

    private let runs = Runs()
    private let work: BackgroundWork

    init() {
        let runs = runs
        work = BackgroundWork(label: "test.files-lane", onRan: { lane, priority, _, _ in runs.record(lane, priority) })
    }

    @Test func newFolderAndRenameRunOnTheFilesLaneAndDeleteOnTheBulkLane() async throws {
        let temp = try TempFolder()
        let files = FileOperator(work: work)
        let folder = try await files.newFolder(in: temp.url, named: "untitled folder")
        let renamed = try await files.rename(folder, to: "kept")
        try await files.deleteImmediately([renamed])
        await runs.wait(for: 3)
        #expect(runs.runs(on: .files).count == 2)
        #expect(runs.runs(on: .bulkFiles).count == 1)
        #expect(runs.runs(on: .files).allSatisfy { $0.priority == .userBlocking })
        #expect(temp.names().isEmpty)
    }

    @Test func newFileTakesTheFirstFreeNameAndNeverReplaces() async throws {
        let temp = try TempFolder()
        try temp.file("untitled", bytes: 3)
        let files = FileOperator(work: work)
        let made = try await files.newFile(in: temp.url, named: "untitled", contents: Data("new".utf8))
        #expect(made.lastPathComponent == "untitled 2")
        #expect(try Data(contentsOf: temp.url.appendingPathComponent("untitled")) == Data(repeating: 0x61, count: 3))
        #expect(try Data(contentsOf: made) == Data("new".utf8))
        await runs.wait(for: 1)
        #expect(runs.runs(on: .files).count == 1)
    }

    @Test func getInfoReadsOnTheFilesLaneAndWalksOnTheBulkLane() async throws {
        let temp = try TempFolder()
        let file = try temp.file("a.txt", bytes: 5)
        let reader = FileInfoReader(work: work) { _ in (important: 7_000, plain: nil) }
        let info = try await reader.info(for: file)
        #expect(info.size == 5)
        #expect(await reader.availableCapacity(of: temp.url) == 7_000)
        #expect(await reader.folderSize(of: temp.url).items == 1)
        await runs.wait(for: 3)
        // Get Info's read (userBlocking) and the free space (userVisible, or the caller's priority when higher).
        #expect(runs.runs(on: .files).count == 2)
        #expect(runs.runs(on: .files).allSatisfy { $0.priority >= .userVisible })
        // The folder size walk, which can take minutes, never holds the serial files slot.
        #expect(runs.runs(on: .bulkFiles).count == 1)
    }

    /// The regression: a long walk or delete held the one serial `.files` slot of its priority, so New Folder,
    /// Rename and every other files-lane call at that priority waited for it. With every bulk slot held, a new
    /// folder still completes (the suite's time limit bounds it).
    @Test func aNewFolderFinishesWhileEveryBulkSlotIsHeld() async throws {
        let temp = try TempFolder()
        let release = DispatchSemaphore(value: 0)
        let (held, hold) = AsyncStream.makeStream(of: Void.self)
        for _ in 0..<BackgroundWork.bulkFilesWidth {
            work.post(.userBlocking, mayBlock: .bulkFiles) {
                hold.yield()
                release.wait()
            }
        }
        var started = 0
        for await _ in held {
            started += 1
            if started == BackgroundWork.bulkFilesWidth { break }
        }
        let made = try await FileOperator(work: work).newFolder(in: temp.url, named: "untitled folder")
        #expect(made.lastPathComponent == "untitled folder")
        for _ in 0..<BackgroundWork.bulkFilesWidth { release.signal() }
    }

    @Test func aTransferRunsEveryFileCallOnTheBulkLane() async throws {
        let temp = try TempFolder()
        try temp.folder("from")
        let source = try temp.file("a.txt", bytes: 4, in: "from")
        let target = try temp.folder("to")
        var finished: [URL: URL] = [:]
        for try await event in FileOperator(work: work).transfer([source], to: target, mode: .copy, resolve: { _ in ConflictAnswer(.keepBoth) }) {
            if case .finished(let placed, _) = event { finished = placed }
        }
        #expect(finished[source] == target.appendingPathComponent("a.txt"))
        #expect(try Data(contentsOf: target.appendingPathComponent("a.txt")).count == 4)
        // The size walk, the conflict probe and the copy: three bulk items, none on the serial files slot.
        await runs.wait(for: 3)
        #expect(runs.runs(on: .bulkFiles).count == 3)
        #expect(runs.runs(on: .files).isEmpty)
    }
}

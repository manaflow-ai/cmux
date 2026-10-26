import CmuxNextWakeups
import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextFiles

/// p02-threads 047-052: the Files pane's file calls run on BackgroundWork's `.files` lane (Chrome's
/// `MayBlock` ThreadPool tasks, base/task/task_traits.h), never on a cooperative pool thread. Each test
/// counts the lane items its calls ran through the lanes' `onRan` hook.
struct FileOperatorLaneTests {
    /// The lane and priority of every item `work` ran, recorded on its lane thread.
    final class Runs: Sendable {
        private let ran = Mutex<[(BlockingLane, WorkPriority)]>([])

        func record(_ lane: BlockingLane, _ priority: WorkPriority) { ran.withLock { $0.append((lane, priority)) } }

        /// The items that ran on `lane` at `priority`.
        func count(_ lane: BlockingLane, _ priority: WorkPriority) -> Int {
            ran.withLock { $0.filter { $0.0 == lane && $0.1 == priority }.count }
        }
    }

    private let runs = Runs()
    private let work: BackgroundWork

    init() {
        let runs = runs
        work = BackgroundWork(label: "test.files-lane", onRan: { lane, priority, _, _ in runs.record(lane, priority) })
    }

    /// One more `.files` item at `priority`: the lane is serial per priority and reports an item before it
    /// starts the next, so every earlier item at `priority` has reported once this returns.
    private func settle(_ priority: WorkPriority) async throws {
        try await work.run(priority, mayBlock: .files) {}
    }

    @Test func newFolderRenameAndDeleteRunOnTheFilesLane() async throws {
        let temp = try TempFolder()
        let files = FileOperator(work: work)
        let folder = try await files.newFolder(in: temp.url, named: "untitled folder")
        let renamed = try await files.rename(folder, to: "kept")
        try await files.deleteImmediately([renamed])
        try await settle(.userBlocking)
        // Three calls and the settle item, each one item on the files lane at userBlocking.
        #expect(runs.count(.files, .userBlocking) == 4)
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
        try await settle(.userBlocking)
        #expect(runs.count(.files, .userBlocking) == 2)
    }

    @Test func getInfoReadsOnTheFilesLane() async throws {
        let temp = try TempFolder()
        let file = try temp.file("a.txt", bytes: 5)
        let reader = FileInfoReader(work: work) { _ in (important: 7_000, plain: nil) }
        let info = try await reader.info(for: file)
        #expect(info.size == 5)
        #expect(await reader.availableCapacity(of: temp.url) == 7_000)
        #expect(await reader.folderSize(of: temp.url).items == 1)
        try await settle(.userBlocking)
        try await settle(.userVisible)
        // Get Info's read at userBlocking; the free space and the folder size at userVisible.
        #expect(runs.count(.files, .userBlocking) == 2)
        #expect(runs.count(.files, .userVisible) == 3)
    }
}

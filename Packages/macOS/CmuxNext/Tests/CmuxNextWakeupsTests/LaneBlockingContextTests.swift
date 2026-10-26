#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A BackgroundWork `.files` or `.system` item runs with its thread marked a lane (`LaneScheduler`), Chrome's
/// `MayBlock()` task: the blocking detector allows its seams (plans/cmux-next/chrome-parity/p02-threads.md, task
/// 005). A `.cpu` item may not block (LaneWrongLaneTests, task 015).
@Suite(.timeLimit(.minutes(1))) struct LaneBlockingContextTests {
    @Test(arguments: [BlockingLane.files, .system])
    func aSeamInsideWorkRunRecordsNothing(lane: BlockingLane) async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let work = BackgroundWork(label: "test.lane-context")
        let context: BlockingContext = try await work.run(.userVisible, mayBlock: lane) { () -> BlockingContext in
            BlockingViolationTable.$scoped.withValue(table) { () -> BlockingContext in
                _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
                return BlockingContext.current()
            }
        }
        await table.flush()

        #expect(context == .lane)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// A posted item (nobody awaits it) is a lane item too.
    @Test func aPostedItemRunsAsALane() async {
        let work = BackgroundWork(label: "test.lane-context")
        let (reports, report) = AsyncStream.makeStream(of: BlockingContext.self)
        work.post(.userVisible, mayBlock: .files) { report.yield(BlockingContext.current()) }
        var iterator = reports.makeAsyncIterator()
        #expect(await iterator.next() == .lane)
    }
}
#endif

#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A BackgroundWork `.files`, `.system` or `.bulkFiles` item runs with its thread marked a lane (`LaneScheduler`), Chrome's
/// `MayBlock()` task: the blocking detector allows its seams (plans/cmux-next/chrome-parity/p02-threads.md, task
/// 005), except a wait on a sync primitive (task 119). A `.cpu` item may not block (LaneWrongLaneTests, task 015).
@Suite(.timeLimit(.minutes(1))) struct LaneBlockingContextTests {
    @Test(arguments: [BlockingLane.files, .system, .bulkFiles])
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

    /// A semaphore wait in a `.files` or `.system` item is a `lane-sync` site at its line, its own kind kept, and a
    /// file read beside it is not (task 119: Chrome runs a `MayBlock()` task under
    /// `ScopedDisallowBaseSyncPrimitives`).
    @Test(arguments: [BlockingLane.files, .system])
    func aSemaphoreWaitInsideWorkRunIsALaneSyncSite(lane: BlockingLane) async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let work = BackgroundWork(label: "test.lane-sync")
        let line: UInt = try await work.run(.userVisible, mayBlock: lane) { () -> UInt in
            BlockingViolationTable.$scoped.withValue(table) { () -> UInt in
                _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
                // Made at 0 and signaled once: a semaphore made at 1 traps when released below that value.
                let semaphore = DispatchSemaphore(value: 0)
                semaphore.signal()
                let line: UInt = #line + 1
                semaphore.blockingWait()
                return line
            }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.context) == [.laneSync])
        #expect(sites.map(\.kind) == [.syncWait])
        #expect(sites.map(\.count) == [1])
        #expect(sites.map(\.location) == ["CmuxNextWakeupsTests/LaneBlockingContextTests.swift:\(line)"])
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

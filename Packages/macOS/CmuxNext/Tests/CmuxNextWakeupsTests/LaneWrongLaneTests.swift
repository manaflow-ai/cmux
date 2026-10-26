#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextWakeups
import Foundation
import Testing

/// The wrong-lane check (plans/cmux-next/chrome-parity/p02-threads.md, task 015): BackgroundWork's `.cpu` lane is
/// sized to the cores and must not block, as Chrome's thread pool runs a task without `MayBlock()` inside
/// `ScopedDisallowBlocking` (base/task/thread_pool/task_tracker.cc). In Debug and bench builds a blocking seam in a
/// `.cpu` job records a `wrong-lane` site in the `cpu-lane` context at its caller's line; in a `.files` or
/// `.system` job it records nothing (task 005: those lanes may block).
///
/// A lane job runs on a lane thread, which does not inherit the test's task-locals, so each job binds the test's
/// own table around its seam call.
@Suite(.timeLimit(.minutes(1))) struct LaneWrongLaneTests {
    /// The file the lane jobs read: it always exists and reads as empty, so no test writes or removes a file.
    private static let url = URL(fileURLWithPath: "/dev/null")

    #if DEBUG || CMUX_BLOCKING_CHECKS
    @Test func aFileReadInACPULaneJobRecordsOneWrongLaneSite() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.cpu")
        let bytes: Data = try await work.run(.userVisible, mayBlock: .cpu) { () throws -> Data in
            try BlockingViolationTable.$scoped.withValue(table) { () throws -> Data in
                try Data(blockingContentsOf: Self.url)
            }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(bytes.isEmpty)
        #expect(sites.map(\.kind) == [.wrongLane])
        #expect(sites.map(\.context) == [.cpuLane])
        #expect(sites.map(\.count) == [1])
    }

    @Test(arguments: [BlockingLane.files, .system])
    func aFileReadInAMayBlockLaneJobRecordsNothing(lane: BlockingLane) async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.\(lane)")
        _ = try await work.run(.userVisible, mayBlock: lane) { () throws -> Data in
            try BlockingViolationTable.$scoped.withValue(table) { () throws -> Data in
                try Data(blockingContentsOf: Self.url)
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// One site per call line: a later wrong-lane call there adds to its count, a posted job is checked as an
    /// awaited one is, and each call outside another one is timed.
    @Test func repeatedCallsAtOneSiteCountOnOneSite() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let work = BackgroundWork(cpuWidth: 2, label: "test.wrong-lane.repeat")
        let read: @Sendable () throws -> Data = {
            try BlockingViolationTable.$scoped.withValue(table) { () throws -> Data in
                try Data(blockingContentsOf: Self.url)
            }
        }
        for _ in 0..<2 {
            _ = try await work.run(.bestEffort, mayBlock: .cpu, read)
        }
        let (posted, done) = AsyncStream.makeStream(of: Void.self)
        work.post(.bestEffort, mayBlock: .cpu) {
            _ = try? read()
            done.yield()
        }
        var iterator = posted.makeAsyncIterator()
        _ = await iterator.next()
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.wrongLane])
        #expect(sites.map(\.count) == [3])
    }

    /// Each lane marks its job's thread: `.cpu` as the cpu lane, `.files` and `.system` as lanes that may block.
    @Test func aLaneJobRunsInItsLanesContext() async throws {
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.context")
        let current: @Sendable () -> BlockingContext = { BlockingContext.current() }
        let cpu: BlockingContext = try await work.run(.userVisible, mayBlock: .cpu, current)
        let files: BlockingContext = try await work.run(.userVisible, mayBlock: .files, current)
        let system: BlockingContext = try await work.run(.userVisible, mayBlock: .system, current)

        #expect(cpu == .cpuLane)
        #expect(files == .lane)
        #expect(system == .lane)
    }

    /// A reviewed `allowBlocking` inside a `.cpu` job marks the thread dedicated for its body, so a seam in it is
    /// not a wrong-lane call, and the job's mark comes back when the body returns.
    @Test func allowBlockingInACPUJobIsNotAWrongLaneCall() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.allowed")
        let seen: [BlockingContext] = try await work.run(.userVisible, mayBlock: .cpu) { () throws -> [BlockingContext] in
            try BlockingViolationTable.$scoped.withValue(table) { () throws -> [BlockingContext] in
                let inside = try allowBlocking(BlockingAllowance(reviewed: "test")) { () throws -> BlockingContext in
                    _ = try Data(blockingContentsOf: Self.url)
                    return BlockingContext.current()
                }
                return [inside, BlockingContext.current()]
            }
        }
        await table.flush()

        #expect(seen == [.dedicated, .cpuLane])
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
    #else
    /// Release: no thread is marked and the check is compiled out, so a seam in a `.cpu` job only runs its body.
    @Test func releaseRecordsNoWrongLaneSite() async throws {
        let detector = BlockingDetector.forProcess()
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.release")
        let bytes: Data = try await work.run(.userVisible, mayBlock: .cpu) { () throws -> Data in
            try Data(blockingContentsOf: Self.url)
        }

        #expect(bytes.isEmpty)
        #expect(!detector.isCompiledIn)
        #expect(detector.sites.isEmpty)
    }
    #endif
}

import CmuxNextCompat
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// The wrong-lane check (plans/cmux-next/chrome-parity/p02-threads.md, task 015): BackgroundWork's `.cpu` lane is sized
/// to the cores and must not block, as Chrome's thread pool runs a task without `MayBlock` inside
/// `ScopedDisallowBlocking` (base/task/thread_pool/task_tracker.cc). In Debug and bench builds a blocking seam in a
/// `.cpu` job records a wrong-lane site at its caller's line; in a `.files` or `.system` job it records nothing.
///
/// A lane job runs on a lane thread, outside the test's task, so its check reports to the process's detector; each
/// test names its own call line as the site and reads only that site.
@Suite(.timeLimit(.minutes(1))) struct LaneWrongLaneTests {
    private let detector = BlockingDetector.forProcess()

    /// The file the lane jobs read: it always exists and reads as empty, so no test writes or removes a file.
    private static let url = URL(fileURLWithPath: "/dev/null")

    /// The detector's sites at `line` of this file.
    private func sites(at line: UInt, fileID: StaticString = #fileID) -> [BlockingSite] {
        detector.sites.filter { $0.location == "\(fileID):\(line)" }
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    @Test func aFileReadInACPULaneJobRecordsOneWrongLaneSite() async throws {
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.cpu")
        let site: UInt = #line
        let bytes = try await work.run(.userVisible, mayBlock: .cpu) { try Data(blockingContentsOf: Self.url, line: site) }

        #expect(bytes.isEmpty)
        #expect(sites(at: site).map(\.kind) == [.wrongLane])
        #expect(sites(at: site).map(\.count) == [1])
    }

    @Test(arguments: [BlockingLane.files, .system])
    func aFileReadInAMayBlockLaneJobRecordsNothing(lane: BlockingLane) async throws {
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.\(lane)")
        let site: UInt = #line
        _ = try await work.run(.userVisible, mayBlock: lane) { try Data(blockingContentsOf: Self.url, line: site) }

        #expect(sites(at: site).isEmpty)
    }

    /// One site per call line: a later wrong-lane call there adds to its count, and a posted job is checked as an
    /// awaited one is.
    @Test func repeatedCallsAtOneSiteCountOnOneSite() async throws {
        let work = BackgroundWork(cpuWidth: 2, label: "test.wrong-lane.repeat")
        let site: UInt = #line
        for _ in 0..<2 {
            _ = try await work.run(.bestEffort, mayBlock: .cpu) { try Data(blockingContentsOf: Self.url, line: site) }
        }
        let (posted, done) = AsyncStream.makeStream(of: Void.self)
        work.post(.bestEffort, mayBlock: .cpu) {
            _ = try? Data(blockingContentsOf: Self.url, line: site)
            done.yield()
        }
        var iterator = posted.makeAsyncIterator()
        _ = await iterator.next()

        #expect(sites(at: site).map(\.kind) == [.wrongLane])
        #expect(sites(at: site).map(\.count) == [3])
    }

    /// Each lane marks its job's thread with its context, and the mark ends with the job: a plain queue's block is
    /// unmarked.
    @Test func aLaneJobRunsInItsLanesContext() async throws {
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.context")
        let current: @Sendable () -> BlockingContext? = { BlockingContext.current }
        let cpu = try await work.run(.userVisible, mayBlock: .cpu, current)
        let files = try await work.run(.userVisible, mayBlock: .files, current)
        let system = try await work.run(.userVisible, mayBlock: .system, current)
        let plain = await Self.onPlainQueue(current)

        #expect(cpu == .cpuLane)
        #expect(files == .lane)
        #expect(system == .lane)
        #expect(plain == nil)
    }

    /// `whileCurrent` nests and restores the outer mark when its body returns.
    @Test func aNestedContextRestoresTheOuterOne() async {
        let seen = await Self.onPlainQueue { () -> [BlockingContext?] in
            let insideOuter = BlockingContext.cpuLane.whileCurrent { () -> [BlockingContext?] in
                let inner = BlockingContext.lane.whileCurrent { () -> BlockingContext? in BlockingContext.current }
                return [inner, BlockingContext.current]
            }
            return insideOuter + [BlockingContext.current]
        }
        #expect(seen == [.lane, .cpuLane, nil])
    }
    #else
    /// Release: no thread is marked and a seam in a `.cpu` job records nothing (the check is compiled out).
    @Test func releaseRecordsNoWrongLaneSite() async throws {
        let work = BackgroundWork(cpuWidth: 1, label: "test.wrong-lane.release")
        let site: UInt = #line
        let context = try await work.run(.userVisible, mayBlock: .cpu) { () throws -> BlockingContext? in
            _ = try Data(blockingContentsOf: Self.url, line: site)
            return BlockingContext.current
        }

        #expect(context == nil)
        #expect(!detector.isCompiledIn)
        #expect(sites(at: site).isEmpty)
    }
    #endif

    /// Runs `body` on a plain serial queue (not a lane) and returns its result.
    private static func onPlainQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            DispatchQueue(label: "test.wrong-lane.plain", qos: .userInitiated).async { done.resume(returning: body()) }
        }
    }
}

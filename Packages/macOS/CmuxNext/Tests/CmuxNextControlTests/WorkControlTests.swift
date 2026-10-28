#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Dispatch
import Testing

/// `debug.work` (RUN-13): per lane and priority the wait and run histograms, the worst lane's
/// user-blocking wait p99 from the same read, and `{"reset": true}` reporting the counts it zeroes.
@Suite(.timeLimit(.minutes(1))) struct WorkControlTests {
    /// A clock that moves only when a lane body moves it.
    final class ManualNanos: Sendable {
        private let now = Mutex(UInt64(0))

        func read() -> UInt64 { now.withLock { $0 } }
        func advance(milliseconds: UInt64) { now.withLock { $0 += milliseconds * 1_000_000 } }
    }

    static let histogramKeys: Set<String> = ["count", "total_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms"]

    /// `report`'s `lanes.<lane>.<priority>.<kind>` object.
    static func histogram(_ report: JSONValue, _ lane: String, _ priority: String, _ kind: String) -> [String: JSONValue]? {
        report.objectValue?["lanes"]?.objectValue?[lane]?.objectValue?[priority]?.objectValue?[kind]?.objectValue
    }

    @Test func reportsEachLaneAndPriorityThenResetsInTheSameRead() async throws {
        let clock = ManualNanos()
        let work = BackgroundWork(cpuWidth: 1, label: "test.work-control", uptimeNanos: { clock.read() })
        let gate = DispatchSemaphore(value: 0)
        // The first holds the files lane's user-blocking slot until the second is queued behind it: the second
        // waits 3 ms, the first runs 3 ms.
        work.post(.userBlocking, mayBlock: .files) {
            gate.wait()
            clock.advance(milliseconds: 3)
        }
        work.post(.userBlocking, mayBlock: .files) {}
        gate.signal()
        // Same level and slot: it runs after both recorded, and reports before it records itself.
        let (first, reset, after) = await withCheckedContinuation { (continuation: CheckedContinuation<(JSONValue, JSONValue, JSONValue), Never>) in
            work.post(.userBlocking, mayBlock: .files) {
                continuation.resume(returning: (WorkControl.report([:], work: work), WorkControl.report(["reset": .bool(true)], work: work),
                                                WorkControl.report([:], work: work)))
            }
        }

        let lanes = try #require(first.objectValue?["lanes"]?.objectValue)
        #expect(Set(lanes.keys) == Set(BlockingLane.allCases.map(\.description)))
        for (lane, priorities) in lanes {
            let priorities = try #require(priorities.objectValue)
            #expect(Set(priorities.keys) == Set(WorkPriority.allCases.map(\.description)), "\(lane)")
            for kinds in priorities.values {
                #expect(Set(kinds.objectValue?.keys.map { $0 } ?? []) == ["wait", "run"])
                #expect(kinds.objectValue?.values.allSatisfy { Set($0.objectValue?.keys.map { $0 } ?? []) == Self.histogramKeys } == true)
            }
        }

        let wait = try #require(Self.histogram(first, "files", "userBlocking", "wait"))
        #expect(wait["count"]?.intValue == 2)
        #expect(wait["total_ms"]?.doubleValue == 3)
        #expect(wait["p99_ms"]?.doubleValue == 4)
        #expect(wait["max_ms"]?.doubleValue == 4)
        #expect((wait["p50_ms"]?.doubleValue ?? 1) < 0.001)
        let run = try #require(Self.histogram(first, "files", "userBlocking", "run"))
        #expect(run["count"]?.intValue == 2)
        #expect(run["total_ms"]?.doubleValue == 3)
        #expect(Self.histogram(first, "cpu", "userBlocking", "wait")?["count"]?.intValue == 0)

        // The top-level p99 is the worst lane's user-blocking wait p99 of the same read.
        let userBlockingP99s = BlockingLane.allCases.compactMap { Self.histogram(first, $0.description, "userBlocking", "wait")?["p99_ms"]?.doubleValue }
        #expect(first.objectValue?["user_blocking_wait_p99_ms"]?.doubleValue == userBlockingP99s.max())
        #expect(first.objectValue?["user_blocking_wait_p99_ms"]?.doubleValue == 4)

        // The resetting report shows what it zeroed; the next one shows nothing.
        #expect(reset == first)
        #expect(after.objectValue?["user_blocking_wait_p99_ms"]?.doubleValue == 0)
        for lane in BlockingLane.allCases {
            for priority in WorkPriority.allCases {
                for kind in ["wait", "run"] {
                    #expect(Self.histogram(after, lane.description, priority.description, kind)?["count"]?.intValue == 0)
                }
            }
        }
    }
}
#endif

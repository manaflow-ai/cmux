#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextWakeups
internal import CmuxNextSettings

/// `debug.work`: per ``BlockingLane`` and ``WorkPriority``, how long the lane items waited for a slot (`wait`,
/// submit to start) and ran (`run`), since launch or the last reset (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 123; RUN-13 reads `user_blocking_wait_p99_ms`). Each histogram has `count`, `total_ms`, `p50_ms`,
/// `p95_ms`, `p99_ms` (interpolated inside log2 buckets) and `max_ms` (the upper edge of the highest bucket with
/// an item, so the longest item took between half of it and it). `{"reset": true}` zeroes every lane's counts in
/// the read the report shows (one atomic exchange per counter), so each item counts in exactly one report. The
/// lanes count in every build; the report reads relaxed atomics only, so it runs off the main thread and answers
/// while the main thread is busy.
public struct WorkControl: Sendable {
    private let work: BackgroundWork

    /// Makes the method over the composition root's lanes.
    public init(work: BackgroundWork) {
        self.work = work
    }

    /// The `debug.work` control method.
    public var method: ControlMethod {
        .snapshot("debug.work") { [work] call in Self.report(call.params, work: work) }
    }

    static func report(_ params: [String: JSONValue], work: BackgroundWork) -> JSONValue {
        let times = work.laneTimes(resetting: params["reset"]?.boolValue == true)
        var lanes: [String: JSONValue] = [:]
        for lane in BlockingLane.allCases {
            var priorities: [String: JSONValue] = [:]
            for entry in times where entry.lane == lane {
                priorities[entry.priority.description] = .object(["wait": json(entry.wait), "run": json(entry.run)])
            }
            lanes[lane.description] = .object(priorities)
        }
        return .object([
            "user_blocking_wait_p99_ms": .number(milliseconds(BackgroundWork.userBlockingQueueWaitP99Nanos(in: times))),
            "lanes": .object(lanes),
        ])
    }

    private static func json(_ histogram: LaneHistogram) -> JSONValue {
        .object([
            "count": .number(Double(histogram.count)),
            "total_ms": .number(milliseconds(histogram.sumNanos)),
            "p50_ms": .number(milliseconds(histogram.percentileNanos(0.50))),
            "p95_ms": .number(milliseconds(histogram.percentileNanos(0.95))),
            "p99_ms": .number(milliseconds(histogram.percentileNanos(0.99))),
            "max_ms": .number(milliseconds(histogram.maxNanos)),
        ])
    }

    private static func milliseconds(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000 }
}
#endif

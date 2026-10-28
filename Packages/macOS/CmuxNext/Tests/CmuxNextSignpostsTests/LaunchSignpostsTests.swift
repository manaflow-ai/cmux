@testable import CmuxNextSignposts
import Testing

/// The launch intervals derived from the launch marks: each opens and closes exactly once over a launch.
@Suite("Launch signposts")
struct LaunchSignpostsTests {
    /// The launch marks in the order `CmuxNextApp.main` and `AppDelegate` record them (scripts/cmux-next/bench-startup.py
    /// MARKS), with daemon and pane marks between them that bound no interval.
    private let launchOrder = [
        "main_start", "main.environment_frozen", "main.warmup_started", "main.app_environment", "main.launch_reads",
        "main.prestart", "main.delegate", "main.nsapp", "main.run",
        "did_finish_launching_start", "dfl.settings_wait", "dfl.settings_read", "dfl.theme",
        "crash.sentry_start", "crash.sentry_started", "services.crash_reporting", "services.cache",
        "services.windows", "services.palette_updater", "dfl.services", "dfl.bind", "dfl.settings", "dfl.menu",
        "daemon.binary_resolved", "dfl.daemon_cloud_updater", "dfl.first_window_hooks", "dfl.home_history",
        "launch_snapshot_shown", "dfl.windows", "did_finish_launching_end", "first_window_frame_committed",
        "daemon.socket_connected", "first_terminal_frame",
    ]

    private func text(_ name: StaticString) -> String {
        name.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
    }

    @Test("Over a launch every interval begins once and then ends once")
    func everyIntervalBeginsAndEndsOnce() {
        var begins: [LaunchSignposts.Interval: Int] = [:]
        var ends: [LaunchSignposts.Interval: Int] = [:]
        for mark in launchOrder {
            let boundary = LaunchSignposts.Interval.boundary(at: mark)
            if let ended = boundary.ends {
                #expect(begins[ended] == 1, "\(ended) ends at \(mark) before it began")
                ends[ended, default: 0] += 1
            }
            if let begun = boundary.begins { begins[begun, default: 0] += 1 }
        }
        for interval in LaunchSignposts.Interval.allCases {
            #expect(begins[interval] == 1, "\(interval) begins \(begins[interval] ?? 0) times")
            #expect(ends[interval] == 1, "\(interval) ends \(ends[interval] ?? 0) times")
        }
    }

    @Test("The boundary switch agrees with each interval's begin and end marks")
    func boundaryMatchesTheMarks() {
        for interval in LaunchSignposts.Interval.allCases {
            #expect(interval.beginMark != interval.endMark)
            #expect(LaunchSignposts.Interval.boundary(at: interval.beginMark).begins == interval)
            #expect(LaunchSignposts.Interval.boundary(at: interval.endMark).ends == interval)
        }
        let unrelated = LaunchSignposts.Interval.boundary(at: "daemon.socket_connected")
        #expect(unrelated.ends == nil && unrelated.begins == nil)
    }

    @Test("Interval names and signpost ids are distinct, and names sit in the launch category")
    func namesAndIDsAreDistinct() {
        let intervals = LaunchSignposts.Interval.allCases
        let names = intervals.map { text($0.name) }
        #expect(Set(names).count == intervals.count)
        #expect(names.allSatisfy { $0.hasPrefix("\(SignpostCategory.launch.rawValue).") })
        #expect(Set(intervals.map(\.signpostID.rawValue)).count == intervals.count)
    }

    @Test("Native library steps have their own names and ids, apart from every interval's")
    func stepsAreDistinctFromIntervals() {
        let steps = LaunchSignposts.Step.allCases
        let names = steps.map { text($0.name) }
        #expect(Set(names).count == steps.count)
        #expect(names.allSatisfy { $0.hasPrefix("\(SignpostCategory.launch.rawValue).") })
        #expect(Set(names).isDisjoint(with: LaunchSignposts.Interval.allCases.map { text($0.name) }))
        let ids = Set(steps.map(\.signpostID.rawValue))
        #expect(ids.count == steps.count)
        #expect(ids.isDisjoint(with: LaunchSignposts.Interval.allCases.map(\.signpostID.rawValue)))
    }

    @Test("A measured step runs its body once and returns its result")
    func measureReturnsTheBodysResult() {
        var runs = 0
        let result = LaunchSignposts().measure(.ghosttyInit) { () -> Int in
            runs += 1
            return 7
        }
        #expect(result == 7)
        #expect(runs == 1)
    }

    @Test("Emitting every launch mark, unknown ones included, needs no state between calls")
    func markEmitsForEveryName() {
        let signposts = LaunchSignposts()
        for (index, mark) in launchOrder.enumerated() { signposts.mark(mark, ms: Double(index)) }
        signposts.mark("not.a.launch.mark", ms: 0)
    }
}

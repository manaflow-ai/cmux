import CmuxNextCompat
import Foundation

/// How much work the sidebar does, for `debug.sidebar_perf` and
/// scripts/cmux-next/sidebar-rows-perf-live.py. A script reads the counters
/// before and after a phase (agent status ticks, a scroll, a drag), so a
/// status tick shows as row patches and row configures, never as rebuilds.
///
/// - `rebuilds`: structural sidebar rebuilds (the App maps every row again).
/// - `section_sets`: structural `SidebarModel.setSections` calls (each arranges and compares every row).
/// - `list_reloads`: full list layouts (`SidebarLayout.make` + apply).
/// - `row_patches`: workspace rows updated in place.
/// - `row_configures`: row views configured (any path).
/// - `selection_patches`: selection changes drawn on the old and new rows only (no list layout).
/// - `scroll_realizes`: realize passes after a scroll.
/// - `ffi_calls`: calls into the Rust sidebar reducer (drag resolve, drop plan).
/// - `band_updates`: top/footer band content recomputes.
/// - `main_ns`: main-thread time spent in the measured paths, nanoseconds.
/// - `order_builds`: `SidebarModel.workspaceOrder` builds (one per structural change at most, never per query).
/// - `mirror_ns`: main-thread time in `SidebarMirror` calls (request encode, the Rust call, reading the reply), nanoseconds.
nonisolated enum SidebarPerfCounters {
    enum Counter: String, CaseIterable, Sendable {
        case rebuilds
        case sectionSets = "section_sets"
        case listReloads = "list_reloads"
        /// A group's fold drawn by splicing its rows (`SidebarListView.foldGroup`), no list reload.
        case groupFolds = "group_folds"
        case rowPatches = "row_patches"
        case rowConfigures = "row_configures"
        case selectionPatches = "selection_patches"
        case scrollRealizes = "scroll_realizes"
        case ffiCalls = "ffi_calls"
        case bandUpdates = "band_updates"
        case mainNanoseconds = "main_ns"
        case mirrorNanoseconds = "mirror_ns"
        case orderBuilds = "order_builds"
    }

    private static let counts = Mutex<[Counter: Int]>([:])
    /// Per-caller counts of the costly counters ("list_reloads@SidebarView+Observation.swift:90"),
    /// so a breach names its cause (perf-gate.py prints them with the breach).
    private static let sources = Mutex<[String: Int]>([:])

    static func add(_ counter: Counter, _ amount: Int = 1) {
        guard amount != 0 else { return }
        counts.withLock { $0[counter, default: 0] += amount }
    }

    /// The current count of `counter`.
    static func count(_ counter: Counter) -> Int { counts.withLock { $0[counter] ?? 0 } }

    /// `add`, also counted under its caller.
    static func add(_ counter: Counter, from file: StaticString, line: UInt) {
        add(counter)
        let name = "\(file)".split(separator: "/").last.map(String.init) ?? "\(file)"
        sources.withLock { $0["\(counter.rawValue)@\(name):\(line)", default: 0] += 1 }
    }

    /// Runs `body` and adds its duration to `main_ns`.
    static func timed<T>(_ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(.mainNanoseconds, Int(DispatchTime.now().uptimeNanoseconds &- start)) }
        return try body()
    }

    /// Runs `body` and adds its duration to `mirror_ns`.
    static func timedMirror<T>(_ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(.mirrorNanoseconds, Int(DispatchTime.now().uptimeNanoseconds &- start)) }
        return try body()
    }
    /// Every counter by name, then each caller count ("<counter>@<file>:<line>"); `reset` zeroes them after reading.
    static func report(reset: Bool) -> [String: Int] {
        var report = counts.withLock { values in
            var report: [String: Int] = [:]
            for counter in Counter.allCases { report[counter.rawValue] = values[counter] ?? 0 }
            if reset { values = [:] }
            return report
        }
        sources.withLock { values in
            report.merge(values) { counter, _ in counter }
            if reset { values = [:] }
        }
        return report
    }
}

extension SidebarView {
    /// `debug.sidebar_perf`: the sidebar work counters (`SidebarPerfCounters`).
    public static func perfCounters(reset: Bool) -> [String: Int] { SidebarPerfCounters.report(reset: reset) }

    /// The App rebuilt a window's sidebar rows from its stores (a structural change).
    public static func countRebuild() { SidebarPerfCounters.add(.rebuilds) }

    /// Runs the App's sidebar work `body`, adding its main-thread time to the counters.
    public static func timedPerf<T>(_ body: () throws -> T) rethrows -> T { try SidebarPerfCounters.timed(body) }
}

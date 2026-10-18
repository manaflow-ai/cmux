import CmuxNextCompat
import CmuxNextControl
import Observation
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTerminal

/// `debug.layout_counters` (DEBUG builds): how much work the app does per
/// layout change, for scripts/cmux-next/bench_pane_scale.py. The bench reads
/// the counters before and after a phase and divides by the op count, so a
/// change that touches one pane should move each counter by O(1), not O(N).
///
/// - `pane_snapshots`: PaneController.snapshot runs (tab strip rebuilds).
/// - `workspace_applies`: WorkspaceContentController.apply runs (tree maps).
/// - `topology_sends`: focus topology rebuilds (O(N) each).
/// - `workspace_window_entries`: workspace content views entering a window (a mount; a switch to a
///   parked workspace unhides it in place and adds none).
/// - `layout_root_layouts`: `LayoutRootView.layout()` passes, all windows (a resize: shown roots only).
/// - `terminal_window_updates`: window notifications terminals handled (shown terminals only).
/// - `pane_count_changes`: each workspace view's shown pane count, appended when an apply changes
///   it (the last 64). A split shows 1, 2; a split undone before its daemon pane lands shows
///   1, 2, 1, 2 (cx-ry0y, scripts/cmux-next/split-no-flicker-e2e.py).
@MainActor
enum DebugLayoutCounters {
    static var paneSnapshots: UInt64 = 0
    static var workspaceApplies: UInt64 = 0
    static var topologySends: UInt64 = 0
    static var workspaceWindowEntries: UInt64 = 0
    static var paneCountChanges: [Int] = []
    /// Each counted call by kind and call site (`sources`), so a budget breach names its caller.
    static var sources: [String: Int] = [:]
    static func note(_ kind: String, _ file: StaticString, _ line: UInt) { sources["\(kind) \(file):\(line)", default: 0] += 1 }
    /// The fields `new` changed from `old` (`items.<field>` for a changed tab), "unchanged" for a
    /// re-run that changed nothing: the observation read something the value does not use (I2).
    static func changedFields<T>(_ old: T?, _ new: T) -> String {
        guard let old else { return "first" }
        func diff(_ a: Any, _ b: Any) -> [String] {
            zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children).compactMap { x, y in
                String(describing: x.value) == String(describing: y.value) ? nil : x.label
            }
        }
        let fields = zip(Mirror(reflecting: old).children, Mirror(reflecting: new).children).flatMap { x, y -> [String] in
            guard String(describing: x.value) != String(describing: y.value), let label = x.label else { return [] }
            guard let a = x.value as? [Any], let b = y.value as? [Any], a.count == b.count else { return [label] }
            let inner = Set(zip(a, b).flatMap { diff($0, $1) }).sorted().map { "\(label).\($0)" }
            return inner.isEmpty ? [label] : inner // elements without fields (ids): the array changed
        }
        return fields.isEmpty ? "unchanged" : fields.joined(separator: ",")
    }
    /// PROBE (side branch only): the latest snapshot run per pane (read where a change fires); an
    /// older run's probes stay silent, and one run counts each group once.
    private static let probeRuns = Mutex<[ObjectIdentifier: Int]>([:])
    private static let probeFired = Mutex<Set<String>>([])
    /// Runs `read` under its own tracking (nested: the caller's tracking still sees each access) and
    /// counts "pane read <group> fired" in `sources` when what it read changes, for the latest run only.
    static func probe<T>(_ group: String, owner: ObjectIdentifier, run: Int, _ read: () -> T) -> T {
        probeRuns.withLock { $0[owner] = run }
        return withObservationTracking(read, onChange: {
            let latest = probeRuns.withLock { $0[owner] == run }
            guard latest, probeFired.withLock({ $0.insert("\(owner.hashValue)#\(run)#\(group)").inserted }) else { return }
            Task { @MainActor in sources["pane read \(group) fired", default: 0] += 1 }
        })
    }
    private static var paneCounts: [ObjectIdentifier: Int] = [:]

    static func notePanes(_ count: Int, of view: AnyObject) {
        let id = ObjectIdentifier(view)
        guard paneCounts[id] != count else { return }
        paneCounts[id] = count
        paneCountChanges.append(count)
        if paneCountChanges.count > 64 { paneCountChanges.removeFirst(paneCountChanges.count - 64) }
    }

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        let report: JSONValue = [
            "pane_snapshots": JSONValue(Int(truncatingIfNeeded: paneSnapshots)),
            "workspace_applies": JSONValue(Int(truncatingIfNeeded: workspaceApplies)),
            "topology_sends": JSONValue(Int(truncatingIfNeeded: topologySends)),
            "workspace_window_entries": JSONValue(Int(truncatingIfNeeded: workspaceWindowEntries)),
            "layout_root_layouts": JSONValue(Int(truncatingIfNeeded: LayoutRootView.layoutPasses)),
            "terminal_window_updates": JSONValue(Int(truncatingIfNeeded: TerminalSurfaceView.windowStateUpdates)),
            "pane_count_changes": .array(paneCountChanges.map { JSONValue($0) }),
            "sources": .object(sources.mapValues { JSONValue($0) }),
        ]
        if params["reset"]?.boolValue == true {
            paneSnapshots = 0
            workspaceApplies = 0
            topologySends = 0
            workspaceWindowEntries = 0
            LayoutRootView.layoutPasses = 0
            TerminalSurfaceView.windowStateUpdates = 0
            paneCountChanges.removeAll()
            sources.removeAll()
        }
        return report
    }
}

import CmuxNextControl
import CmuxNextSettings

/// `debug.layout_counters` (DEBUG builds): how much work the app does per
/// layout change, for scripts/cmux-next/bench_pane_scale.py. The bench reads
/// the counters before and after a phase and divides by the op count, so a
/// change that touches one pane should move each counter by O(1), not O(N).
///
/// - `pane_snapshots`: PaneController.snapshot runs (tab strip rebuilds).
/// - `workspace_applies`: WorkspaceContentController.apply runs (tree maps).
/// - `topology_sends`: focus topology rebuilds (O(N) each).
/// - `pane_count_changes`: each workspace view's shown pane count, appended when an apply changes
///   it (the last 64). A split shows 1, 2; a split undone before its daemon pane lands shows
///   1, 2, 1, 2 (cx-ry0y, scripts/cmux-next/split-no-flicker-e2e.py).
@MainActor
enum DebugLayoutCounters {
    static var paneSnapshots: UInt64 = 0
    static var workspaceApplies: UInt64 = 0
    static var topologySends: UInt64 = 0
    static var paneCountChanges: [Int] = []
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
            "pane_count_changes": .array(paneCountChanges.map { JSONValue($0) }),
        ]
        if params["reset"]?.boolValue == true {
            paneSnapshots = 0
            workspaceApplies = 0
            topologySends = 0
            paneCountChanges.removeAll()
        }
        return report
    }
}

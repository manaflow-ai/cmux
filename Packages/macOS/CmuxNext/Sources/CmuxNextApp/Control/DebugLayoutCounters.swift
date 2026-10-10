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
@MainActor
enum DebugLayoutCounters {
    static var paneSnapshots: UInt64 = 0
    static var workspaceApplies: UInt64 = 0
    static var topologySends: UInt64 = 0

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        let report: JSONValue = [
            "pane_snapshots": JSONValue(Int(truncatingIfNeeded: paneSnapshots)),
            "workspace_applies": JSONValue(Int(truncatingIfNeeded: workspaceApplies)),
            "topology_sends": JSONValue(Int(truncatingIfNeeded: topologySends)),
        ]
        if params["reset"]?.boolValue == true {
            paneSnapshots = 0
            workspaceApplies = 0
            topologySends = 0
        }
        return report
    }
}

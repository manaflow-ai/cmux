import CmuxNextControl
import CmuxNextDesign
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
/// - `pane_chrome_updates`: panes whose chrome (ring, dim, tab emphasis) a layout sync re-ran; a
///   pane focus move re-runs the pane left and the pane focused only (perf-gate.py pane_focus).
/// - `layout_root_layouts`: `LayoutRootView.layout()` passes, all windows (a resize: shown roots only).
/// - `terminal_window_updates`: window notifications terminals handled (shown terminals only).
/// - `terminal_grid_reports`: grids terminals reported to their session (one PTY resize and shell
///   redraw each). A motion that moves the content edge over frames (a pane's layout spring, the
///   sidebar sliding) should add one per terminal, at the landing, not one per frame
///   (`RestingPlacement`, scripts/ci/frame-pacing/golden.py `sidebar_*`). `reset` leaves this one
///   alone: `debug.window_transition` holds a baseline of it and subtracts.
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
            "pane_chrome_updates": JSONValue(Int(truncatingIfNeeded: LayoutRootView.paneChromeUpdates)),
            "terminal_window_updates": JSONValue(Int(truncatingIfNeeded: TerminalSurfaceView.windowStateUpdates)),
            "terminal_grid_reports": JSONValue(Int(truncatingIfNeeded: TerminalSurfaceView.gridReports)),
            "indicator_resyncs": JSONValue(Int(truncatingIfNeeded: StatusIndicatorAppearance.resyncs)),
            "pane_count_changes": .array(paneCountChanges.map { JSONValue($0) }),
            "sources": .object(sources.mapValues { JSONValue($0) }),
        ]
        if params["reset"]?.boolValue == true {
            paneSnapshots = 0
            workspaceApplies = 0
            topologySends = 0
            workspaceWindowEntries = 0
            LayoutRootView.layoutPasses = 0
            LayoutRootView.paneChromeUpdates = 0
            TerminalSurfaceView.windowStateUpdates = 0
            StatusIndicatorAppearance.resyncs = 0
            paneCountChanges.removeAll()
            sources.removeAll()
        }
        return report
    }
}

import CmuxNextControl
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups

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
/// - `update_visibility`: `LayoutRootView.updateVisibility()` calls of the mounted roots (`roots`: every
///   window's shown and parked workspaces); DC2 of plans/cmux-next/chrome-parity/p03-rendering.md wants
///   <= 2 per spring (motion-main-work.py). Per-root counts, so `reset` leaves it: read a delta.
/// - `presented_hit_reads`: presentation-layer reads of pane hit tests of the mounted roots
///   (`LayoutRootView.presentedHitReads`): one per moving host for a press mid render-server spring, none
///   for a press at rest. Per-host counts: read a delta.
/// - `presses_mid_spring`: presses the layout's intercept handled while render-server springs ran on the
///   active screen (`LayoutRootView.pressesMidRenderSpring`), whatever their hit test read: when a press came
///   (every-action-sweep.py `click.during_motion`). Read a delta.
/// - `scroll_routes`: scrolls the layout's intercept sent through its full routing, with its pane hit tests
///   and claim queries (`LayoutRootView.routedScrolls`); a page's plain scroll and the changes and coast of a
///   gesture the layout did not take add none. Cumulative per root: read a delta.
/// - `scroll_conversions`: scroll points the layout's intercept converted from a child window (a page, a
///   divider catcher) into its own (`LayoutRootView.scrollPointConversions`); a page's plain scroll adds none.
///   Cumulative per root: read a delta.
/// - `terminal_window_updates`: window notifications terminals handled (shown terminals only).
/// - `terminal_grid_reports`: grids terminals reported to their session (one PTY resize and shell
///   redraw each). A motion that moves the content edge over frames (a pane's layout spring, the
///   sidebar sliding) should add one per terminal, at the landing, not one per frame
///   (`RestingPlacement`, scripts/ci/frame-pacing/golden.py `sidebar_*`). `reset` leaves this one
///   alone: `debug.window_transition` holds a baseline of it and subtracts.
/// - `pane_count_changes`: each workspace view's shown pane count, appended when an apply changes
///   it (the last 64). A split shows 1, 2; a split undone before its daemon pane lands shows
///   1, 2, 1, 2 (cx-ry0y, scripts/cmux-next/split-no-flicker-e2e.py).
/// - `hidden_workspace_layouts`: layout passes of the mounted roots while their workspace is off screen (parked and
///   on no screen, `WorkspaceContentController.isOffScreen`: its visibility node hidden). A
///   hidden workspace's changes update the model only, so this stays 0 (p06-scheduler.md done checks 4 and 6;
///   bench_idle.py, script-storm-bench.py `--hidden`). The app's `HiddenLayoutWork`: all roots, kept when one unmounts.
/// - `hidden_workspace_applies`: tree changes that reached a mounted off-screen workspace: each updates the handles
///   only and is kept for its show, where the last one applies once (no view sync, no topology while hidden).
/// - `appearance_applies`: appearance bodies run through `VisibilityNode.deferAppearance` under the app's roots
///   (`AppServices.visibilityWorkCounts`, recipe R-appear): a theme
///   flip at 50 workspaces adds one per owner on screen, then one per owner of each workspace as it shows
///   (p06-scheduler.md done check 10).
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

    /// - Parameters:
    ///   - roots: Every window's mounted workspace roots, shown and parked.
    ///   - hiddenWork: The app's off-screen work counts (`AppServices.hiddenLayoutWork`).
    ///   - visibilityWork: What the visibility tree ran for what shows (`AppServices.visibilityWorkCounts`).
    static func handle(_ params: [String: JSONValue], roots: [LayoutRootView] = [],
                       hiddenWork: HiddenLayoutWork? = nil, visibilityWork: VisibilityWorkCounts? = nil) -> JSONValue {
        let visibilityUpdates = roots.reduce(UInt64(0)) { $0 &+ $1.visibilityUpdates }
        let presentedHitReads = roots.reduce(0) { $0 + $1.presentedHitReads }
        let report: JSONValue = [
            "pane_snapshots": JSONValue(Int(truncatingIfNeeded: paneSnapshots)),
            "workspace_applies": JSONValue(Int(truncatingIfNeeded: workspaceApplies)),
            "topology_sends": JSONValue(Int(truncatingIfNeeded: topologySends)),
            "workspace_window_entries": JSONValue(Int(truncatingIfNeeded: workspaceWindowEntries)),
            "layout_root_layouts": JSONValue(Int(truncatingIfNeeded: LayoutRootView.layoutPasses)),
            "pane_chrome_updates": JSONValue(Int(truncatingIfNeeded: LayoutRootView.paneChromeUpdates)),
            "update_visibility": JSONValue(Int(truncatingIfNeeded: visibilityUpdates)),
            "presented_hit_reads": JSONValue(presentedHitReads),
            "presses_mid_spring": JSONValue(roots.reduce(0) { $0 + $1.pressesMidRenderSpring }),
            "scroll_routes": JSONValue(Int(truncatingIfNeeded: roots.reduce(UInt64(0)) { $0 &+ $1.routedScrolls })),
            "scroll_conversions": JSONValue(Int(truncatingIfNeeded: roots.reduce(UInt64(0)) { $0 &+ $1.scrollPointConversions })),
            "terminal_window_updates": JSONValue(Int(truncatingIfNeeded: TerminalSurfaceView.windowStateUpdates)),
            "terminal_grid_reports": JSONValue(Int(truncatingIfNeeded: TerminalSurfaceView.gridReports)),
            "indicator_resyncs": JSONValue(Int(truncatingIfNeeded: StatusIndicatorAppearance.resyncs)),
            "appearance_applies": JSONValue(Int(truncatingIfNeeded: visibilityWork?.appearanceApplies ?? 0)),
            "pane_count_changes": .array(paneCountChanges.map { JSONValue($0) }),
            "sources": .object(sources.mapValues { JSONValue($0) }),
            "hidden_workspace_layouts": JSONValue(Int(truncatingIfNeeded: hiddenWork?.layoutPasses ?? 0)),
            "hidden_workspace_applies": JSONValue(Int(truncatingIfNeeded: hiddenWork?.applies ?? 0)),
        ]
        if params["reset"]?.boolValue == true {
            paneSnapshots = 0
            workspaceApplies = 0
            topologySends = 0
            workspaceWindowEntries = 0
            hiddenWork?.reset()
            LayoutRootView.layoutPasses = 0
            LayoutRootView.paneChromeUpdates = 0
            TerminalSurfaceView.windowStateUpdates = 0
            StatusIndicatorAppearance.resyncs = 0
            visibilityWork?.reset()
            paneCountChanges.removeAll()
            sources.removeAll()
        }
        return report
    }
}

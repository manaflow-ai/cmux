import AppKit
import Bonsplit
import CmuxTerminal
import Foundation
import Observation

/// Owns the per-pane ``TerminalPanel``s and current layout for ONE mirrored tmux
/// window, so a single cmux tab can render the tmux window's full multi-pane
/// split layout side by side — with the native cmux pane chrome (each pane is a
/// real ``TerminalPanel`` rendered via ``TerminalPanelView``).
///
/// Created lazily by ``RemoteTmuxSessionMirror`` the first time a window has more
/// than one pane; once created it owns every pane's panel for that window. The
/// remote tmux control stream is the source of truth: pane output is fed into
/// the matching surface, typed input is forwarded to that pane via `send-keys`,
/// and a user split is propagated to `split-window`.
///
/// SIZING IS FEED-FORWARD. The size pushed to tmux (``updateClientSize()``) is
/// a pure function of the container's pixel size, the BASE layout tree's
/// STRUCTURE, and measured render constants (``RemoteTmuxMirrorGeometry``) —
/// never of tmux-assigned geometry or rendered grids. The render
/// (``framesForRender(containerPt:)``) imposes tmux's assigned cells verbatim.
/// Neither direction measures the other back, so tmux's `%layout-change` echo
/// of our own push recomputes to the identical size and dedups to silence:
/// there is no feedback loop to gate, budget, or pin against. Pane ratios are
/// user state and are never written.
@MainActor
@Observable
final class RemoteTmuxWindowMirror {
    /// tmux window id (the `@N` without the sigil).
    let windowId: Int
    /// The bonsplit tab's panel id this window renders into.
    let panelId: UUID

    @ObservationIgnored private weak var connection: RemoteTmuxControlConnection?
    /// Creates a configured manual-I/O pane panel whose input goes to `tmuxPaneId`.
    @ObservationIgnored private let makePanel: (_ tmuxPaneId: Int) -> TerminalPanel?

    /// The window's BASE pane layout (tmux's full tree even while a pane is
    /// zoomed). Drives panel lifecycle and the sizing structure fold.
    private(set) var layout: RemoteTmuxLayoutNode
    /// The layout tmux is DISPLAYING (the single-pane tree while zoomed,
    /// `nil`/base otherwise). Rendering imposes this tree; panel lifecycle
    /// never keys off it — zooming must not close the hidden panes' panels.
    private(set) var visibleLayout: RemoteTmuxLayoutNode?
    /// Whether the window is zoomed right now — per-event derived state from
    /// tmux's flags (never latched: tmux auto-unzooms on its own, e.g. when a
    /// hidden pane is killed while zoomed).
    private(set) var zoomed = false
    /// Bumped by ``reconcile(layout:)`` only when the base layout's STRUCTURE
    /// changes (pane set or split nesting — see ``structureSignature(of:)``),
    /// never on a geometry-only reflow. The view re-pushes sizing off this:
    /// structure changes the chrome fold's output, geometry does not — and
    /// geometry-only events are usually the echo of our own push, which
    /// recomputes to the identical size anyway (the feed-forward invariant).
    private(set) var layoutStructureVersion = 0
    /// The tmux pane the user last focused (drives the focus overlay + splits).
    private(set) var activePaneId: Int?

    /// Only the VISIBLE tab's mirror is a sizing writer. Tabs stay mounted
    /// across selection (keepAllAlive), so a hidden mirror still receives
    /// geometry callbacks — but its container reports collapsed/stale sizes
    /// while hidden, and pushing from those resizes the remote window
    /// underneath the visible state. The view keeps this current; hidden
    /// mirrors send nothing and push once on becoming visible.
    @ObservationIgnored var isVisibleForSizing = true

    /// ``TerminalPanel`` per tmux pane id. Not observation-tracked: the view
    /// re-reads it whenever ``layout`` (which IS tracked) changes, and the two
    /// are always updated together in ``reconcile(layout:)``.
    @ObservationIgnored private var panelsByPaneId: [Int: TerminalPanel] = [:]
    /// Stable synthetic bonsplit pane id per tmux pane (for portal hosting),
    /// minted at panel-creation time so the view body is a pure read.
    @ObservationIgnored private var syntheticPaneIds: [Int: PaneID] = [:]

    // MARK: Sizing inputs (locally owned; never tmux-derived)

    /// The mirror container's last-known size in points (from the view's
    /// GeometryReader) — one of f's two variable inputs.
    @ObservationIgnored private var containerSizePt: CGSize?
    /// The hosting window's backing scale, delivered with the container size.
    @ObservationIgnored private var containerScale: CGFloat?
    /// Monotone minimum of `surface_px − cols·cell_px` observed per axis: the
    /// ghostty padding estimate, KEYED BY BACKING SCALE. A single sample
    /// overestimates padding by the quantization remainder (< one cell),
    /// which only makes f conservative by at most one column; the minimum
    /// converges to the true padding within a few distinct sizes and never
    /// grows. Padding is a device-pixel constant PER SCALE (8px at 2×, ~4px
    /// at 1×): mixing samples across a 1×↔2× display move would drag the 2×
    /// minimum permanently below truth and overshoot f by a column.
    @ObservationIgnored private var minNonGridWidthPxByScale: [CGFloat: Int] = [:]
    @ObservationIgnored private var minNonGridHeightPxByScale: [CGFloat: Int] = [:]

    init(
        windowId: Int,
        panelId: UUID,
        connection: RemoteTmuxControlConnection,
        layout: RemoteTmuxLayoutNode,
        makePanel: @escaping (_ tmuxPaneId: Int) -> TerminalPanel?
    ) {
        self.windowId = windowId
        self.panelId = panelId
        self.connection = connection
        self.makePanel = makePanel
        self.layout = layout
        reconcile(layout: layout)
    }

    /// All tmux pane ids currently in the window, depth-first left→right.
    var paneIDsInOrder: [Int] { layout.paneIDsInOrder }

    /// The panel rendering `tmuxPaneId`, if it exists.
    func panel(forPane tmuxPaneId: Int) -> TerminalPanel? { panelsByPaneId[tmuxPaneId] }

    /// The surface rendering `tmuxPaneId`, if it exists.
    func surface(forPane tmuxPaneId: Int) -> TerminalSurface? { panelsByPaneId[tmuxPaneId]?.surface }

    /// The stable synthetic bonsplit pane id for `tmuxPaneId`, or `nil` if no panel
    /// exists for it (minted in ``reconcile(layout:)``; a pure read here so it's
    /// body-safe). Returns `nil` rather than minting a throwaway `PaneID()` on a miss,
    /// which would churn the portal-host lease keyed off this id.
    func syntheticPaneID(forPane tmuxPaneId: Int) -> PaneID? {
        syntheticPaneIds[tmuxPaneId]
    }

    /// Applies a full window update: panel lifecycle + sizing structure from
    /// the BASE tree, rendering tree from the VISIBLE one. Zoom therefore
    /// never creates or closes panels, and f's output is zoom-invariant.
    func apply(window: RemoteTmuxWindow) {
        reconcile(layout: window.layout)
        let newVisible = window.zoomed ? window.visibleLayout : nil
        if visibleLayout != newVisible { visibleLayout = newVisible }
        if zoomed != window.zoomed { zoomed = window.zoomed }
    }

    /// Updates the base layout, creating panels for new panes and tearing down
    /// panels for panes tmux removed (surviving panes keep their panel and
    /// scrollback).
    func reconcile(layout newLayout: RemoteTmuxLayoutNode) {
        let livePaneIds = Set(newLayout.paneIDsInOrder)
        for paneId in newLayout.paneIDsInOrder where panelsByPaneId[paneId] == nil {
            guard let panel = makePanel(paneId) else { continue }
            panelsByPaneId[paneId] = panel
            syntheticPaneIds[paneId] = PaneID()
            // Canonical seed (reflow classification → capture → cwd). The session
            // mirror's cwd observer maps the pane back to this window's tab.
            connection?.seedPane(paneId: paneId)
        }
        for (paneId, panel) in panelsByPaneId where !livePaneIds.contains(paneId) {
            // Use the full panel close (detaches the portal from the registry
            // BEFORE freeing the surface) so a stale portal entry can't be
            // dereferenced by a later Core Animation commit.
            panel.close()
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
            panelsByPaneId[paneId] = nil
            syntheticPaneIds[paneId] = nil
            if activePaneId == paneId { activePaneId = nil }
        }
        // Structural change (split/close/re-nest) vs geometry-only reflow: only
        // the former re-arms client sizing (the chrome fold's output changed).
        // `init` reconciles the layout it just stored, so the first pass never
        // bumps — the view's onAppear owns the initial push.
        if Self.structureSignature(of: newLayout) != Self.structureSignature(of: layout) {
            layoutStructureVersion += 1
        }
        if layout != newLayout { layout = newLayout }
    }

    /// Routes a tmux `%output` to the surface for `paneId` (no-op if unknown).
    func routeOutput(paneId: Int, data: Data) {
        panelsByPaneId[paneId]?.surface.processRemoteOutput(data)
    }

    /// Records the container's size (points) and backing scale — f's variable
    /// inputs, delivered by the view on mount and every geometry change.
    func noteContainerSize(pointSize: CGSize, scale: CGFloat) {
        containerSizePt = pointSize
        containerScale = scale
    }

    /// The measured render constants, derived from any live pane surface.
    /// Returns `nil` until a surface reports real metrics (the view retries).
    /// Ingests the panes' current sizing samples into the min-tracked pad
    /// constants. Called from EVENT paths only (client-size pushes, sizing
    /// snapshots) — never from render projection, which must stay pure
    /// (``currentGeometry()`` only reads).
    private func refreshGeometryConstants() {
        for panel in panelsByPaneId.values {
            guard let sample = panel.surface.rawSizingSample(),
                  sample.cellWidthPx > 0, sample.cellHeightPx > 0,
                  sample.columns > 1, sample.rows > 1,
                  let scale = sample.backingScale ?? containerScale, scale > 0
            else { continue }
            let nonGridW = sample.surfaceWidthPx - sample.columns * sample.cellWidthPx
            let nonGridH = sample.surfaceHeightPx - sample.rows * sample.cellHeightPx
            if nonGridW >= 0 {
                minNonGridWidthPxByScale[scale] = min(minNonGridWidthPxByScale[scale] ?? nonGridW, nonGridW)
            }
            if nonGridH >= 0 {
                minNonGridHeightPxByScale[scale] = min(minNonGridHeightPxByScale[scale] ?? nonGridH, nonGridH)
            }
        }
    }

    /// The measured render constants, or nil while no pane surface has real
    /// metrics yet. PURE — reads samples and the stored pad minimums without
    /// updating them, so it is safe to call from view-body projection
    /// (`framesForRender`). ``refreshGeometryConstants()`` is what advances
    /// the minimums, on event paths.
    func currentGeometry() -> RemoteTmuxMirrorGeometry? {
        #if DEBUG
        if let geometryOverrideForTesting { return geometryOverrideForTesting }
        #endif
        for panel in panelsByPaneId.values {
            guard let sample = panel.surface.rawSizingSample(),
                  sample.cellWidthPx > 0, sample.cellHeightPx > 0,
                  sample.columns > 1, sample.rows > 1,
                  let scale = sample.backingScale ?? containerScale, scale > 0
            else { continue }
            let nonGridW = sample.surfaceWidthPx - sample.columns * sample.cellWidthPx
            let nonGridH = sample.surfaceHeightPx - sample.rows * sample.cellHeightPx
            return RemoteTmuxMirrorGeometry(
                cellWidthPx: sample.cellWidthPx,
                cellHeightPx: sample.cellHeightPx,
                surfacePadWidthPx: minNonGridWidthPxByScale[scale] ?? max(0, nonGridW),
                surfacePadHeightPx: minNonGridHeightPxByScale[scale] ?? max(0, nonGridH),
                headerHeightPt: RemoteTmuxPaneHeader.totalHeightPt,
                scale: scale
            )
        }
        return nil
    }

    /// Pushes this window's client size to tmux: f(container pixels, base
    /// structure, measured constants) via the connection's per-window form
    /// (dedup and reconnect reseed live there). Feed-forward by construction —
    /// reads no tmux-assigned geometry and no rendered grids, so echo events recompute
    /// to the identical size. Returns `false` while the constants or the
    /// container size are still unknown, so the caller retries; hidden mirrors
    /// return `true` without sending (they push on becoming visible).
    @discardableResult
    func updateClientSize() -> Bool {
        guard let connection else { return true }
        // Hidden mirrors write exactly ONCE — the initial claim. The first
        // per-window size on a connection drops every window WITHOUT one to
        // tmux's 80×24 default, so each mirrored window must claim its size
        // at attach even if its tab isn't selected yet. After that claim,
        // only the visible tab's mirror writes (hidden geometry callbacks
        // report collapsed sizes and must not resize the remote window
        // underneath the visible state).
        guard isVisibleForSizing || connection.lastWindowSizes[windowId] == nil else {
            return true
        }
        refreshGeometryConstants()
        guard let containerSizePt, let containerScale,
              containerSizePt.width > 1, containerSizePt.height > 1,
              let geometry = currentGeometry()
        else { return false }
        let cells = geometry.clientCells(
            pixelWidth: Int(containerSizePt.width * containerScale),
            pixelHeight: Int(containerSizePt.height * containerScale),
            structure: layout
        )
        connection.setWindowSize(windowId: windowId, columns: cells.cols, rows: cells.rows)
        return true
    }

    /// The exact frames to impose for the current tmux layout, or `nil` when the
    /// render should fall back to the proportional TRANSIENT mode: constants
    /// still unknown, or tmux's layout doesn't match what f wants for the current
    /// pixels (a push is in flight — drag mid-motion, attach settling, or a
    /// co-attached client constraining the size). The transient mode always
    /// fits by construction; imposition resumes on tmux's layout that matches.
    func framesForRender(containerPt: CGSize) -> RemoteTmuxMirrorFrames? {
        guard let geometry = currentGeometry(), let containerScale else { return nil }
        let cells = geometry.clientCells(
            pixelWidth: Int(containerPt.width * containerScale),
            pixelHeight: Int(containerPt.height * containerScale),
            structure: layout
        )
        guard layout.width == cells.cols, layout.height == cells.rows else { return nil }
        return geometry.frames(layout: visibleLayout ?? layout, containerPt: containerPt)
    }

    /// The split-tree SHAPE (node kinds + pane ids, geometry stripped). Two layouts
    /// with the same signature differ only in cell extents — the fingerprint of a
    /// tmux-side reflow: the echo of our own push, or a co-attached client's
    /// `resize-pane`. Those must not re-arm client sizing (f recomputes to the
    /// same value; only structure changes its output). A split, close, or
    /// re-nest changes the signature, and those MUST re-push: each split adds
    /// a pane's chrome to the fold. Pure over the node — `nonisolated` and
    /// unit-testable.
    nonisolated static func structureSignature(of node: RemoteTmuxLayoutNode) -> String {
        switch node.content {
        case let .pane(paneId):
            return "p\(paneId)"
        case let .horizontal(children):
            return "h(" + children.map(structureSignature(of:)).joined(separator: ",") + ")"
        case let .vertical(children):
            return "v(" + children.map(structureSignature(of:)).joined(separator: ",") + ")"
        }
    }

    /// Records the user-focused pane and asks tmux to make it active.
    func focus(pane tmuxPaneId: Int) {
        if activePaneId != tmuxPaneId { activePaneId = tmuxPaneId }
        connection?.send("select-pane -t @\(windowId).%\(tmuxPaneId)")
    }

    /// Propagates a user split of `tmuxPaneId` to tmux `split-window`
    /// (`-h` = side-by-side, `-v` = stacked). The new pane arrives via the
    /// resulting `%layout-change` → ``reconcile(layout:)``.
    @discardableResult
    func requestSplit(fromPane tmuxPaneId: Int, vertical: Bool) -> Bool {
        guard let connection, connection.connectionState == .connected else { return false }
        return connection.send("split-window \(vertical ? "-v" : "-h") -t @\(windowId).%\(tmuxPaneId)")
    }

    /// Propagates a user close of `tmuxPaneId` to tmux `kill-pane`. The pane is
    /// removed via the resulting `%layout-change` (or `%window-close` if it was
    /// the window's last pane).
    func requestKillPane(_ tmuxPaneId: Int) {
        connection?.send("kill-pane -t @\(windowId).%\(tmuxPaneId)")
    }

    /// The pane's last-known foreground classification (alt-screen flag +
    /// `pane_current_command`), driving the kill-pane close confirmation.
    /// `nil` when the pane was never classified (closes without a dialog).
    func paneForegroundState(_ tmuxPaneId: Int) -> RemoteTmuxControlConnection.PaneForegroundState? {
        connection?.paneForegroundStates[tmuxPaneId]
    }

    /// Live, close-time query of `tmuxPaneId`'s foreground state (see
    /// ``RemoteTmuxControlConnection/queryPaneActivity(paneId:completion:)``).
    /// Completes with `nil` when the connection is gone — the caller falls back
    /// to ``paneForegroundState(_:)``.
    func queryPaneActivity(
        _ tmuxPaneId: Int,
        completion: @escaping ([Int: RemoteTmuxControlConnection.PaneForegroundState]?) -> Void
    ) {
        guard let connection else {
            completion(nil)
            return
        }
        connection.queryPaneActivity(paneId: tmuxPaneId, completion: completion)
    }

    /// Read-only sizing introspection for the `remote.tmux.pane_grids` socket
    /// command (see ``RemoteTmuxWindowMirrorSizingSnapshot``). A harness can
    /// assert renders match the assigned sizes directly instead of reading pixels off a
    /// screenshot.
    typealias SizingSnapshot = RemoteTmuxWindowMirrorSizingSnapshot

    func sizingSnapshot() -> SizingSnapshot {
        var panes: [SizingSnapshot.Pane] = []
        // exactCols/exactRows encode the render contract per axis: a leaf is
        // exact on its IMMEDIATE parent split's axis and FILLS the other axis
        // (g's split-axis-exact / cross-axis-fill rule). Exactness does not
        // inherit from grandparents: a v-child's width fills a column frame
        // whose rails carry the +1 device-px boundary bias, so it may
        // legitimately render one column past the assignment — background
        // beyond the PTY, never content loss.
        func walk(_ n: RemoteTmuxLayoutNode, exactCols: Bool, exactRows: Bool) {
            switch n.content {
            case let .pane(id):
                let surface = panelsByPaneId[id]?.surface
                let rendered = surface?.renderedGridCells()
                let diagnostics = surface?.renderedGridDiagnostics()
                panes.append(SizingSnapshot.Pane(
                    paneId: id,
                    assignedCols: n.width,
                    assignedRows: n.height,
                    renderedCols: rendered?.columns,
                    renderedRows: rendered?.rows,
                    exactCols: exactCols,
                    exactRows: exactRows,
                    hasPanel: surface != nil,
                    viewInWindow: diagnostics?.viewInWindow,
                    surfaceLive: diagnostics?.surfaceLive,
                    calibration: surface?.rawSizingSample()
                ))
            case let .horizontal(children):
                children.forEach { walk($0, exactCols: true, exactRows: false) }
            case let .vertical(children):
                children.forEach { walk($0, exactCols: false, exactRows: true) }
            }
        }
        walk(layout, exactCols: false, exactRows: false)
        let pushed = connection?.lastWindowSizes[windowId]
        refreshGeometryConstants()
        var fCells: (cols: Int, rows: Int)?
        if let containerSizePt, let containerScale, let geometry = currentGeometry() {
            fCells = geometry.clientCells(
                pixelWidth: Int(containerSizePt.width * containerScale),
                pixelHeight: Int(containerSizePt.height * containerScale),
                structure: layout
            )
        }
        return SizingSnapshot(
            windowId: windowId,
            panes: panes,
            baseCols: layout.width,
            baseRows: layout.height,
            pushedColumns: pushed?.0,
            pushedRows: pushed?.1,
            zoomed: zoomed,
            structureVersion: layoutStructureVersion,
            visibleForSizing: isVisibleForSizing,
            containerPt: containerSizePt,
            currentFCols: fCells?.cols,
            currentFRows: fCells?.rows
        )
    }

    #if DEBUG
    /// Stubs the measured render constants so sizing behavior is testable
    /// without live surfaces: `updateClientSize()`'s readiness/feed-forward
    /// contract and — critically — that ``reconcile(layout:)`` never pushes a
    /// size by itself (pushing from the reconcile path would react to tmux's
    /// own layout events, the direction the feed-forward design forbids).
    @ObservationIgnored var geometryOverrideForTesting: RemoteTmuxMirrorGeometry?
    /// The last per-window size any writer requested for THIS window on the
    /// shared connection — what dedup compares against and a send updates.
    var lastWindowSizeForTesting: (cols: Int, rows: Int)? {
        connection?.lastWindowSizes[windowId].map { (cols: $0.0, rows: $0.1) }
    }
    #endif

    /// Tears down every pane panel (called when the window-tab is removed).
    func teardown() {
        // Unsubscribe each pane's cwd subscription first — matching reconcile(layout:),
        // which unsubscribes per removed pane. Without this, a control connection that
        // outlives the tab keeps streaming pane_current_path updates into a dead mirror.
        for paneId in panelsByPaneId.keys {
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
        }
        for panel in panelsByPaneId.values { panel.close() }
        panelsByPaneId.removeAll()
        syntheticPaneIds.removeAll()
        activePaneId = nil
    }
}

/// Per-window sizing introspection returned by
/// ``RemoteTmuxWindowMirror/sizingSnapshot()`` and serialized by the
/// `remote.tmux.pane_grids` socket command: each pane's tmux-assigned dims (the
/// window's base layout node) next to the grid its ghostty surface actually
/// renders, plus the sizing state around them.
///
/// Top-level and `Sendable` (not nested in the `@MainActor` mirror) so socket
/// handlers can carry it off the main actor after a `MainActor.run` read —
/// the same shape as ``RemoteTmuxControlConnectionSnapshot``.
struct RemoteTmuxWindowMirrorSizingSnapshot: Sendable {
    struct Pane: Sendable {
        let paneId: Int
        let assignedCols: Int
        let assignedRows: Int
        let renderedCols: Int?
        let renderedRows: Int?
        /// Which axes the render contract requires to be EXACT (the leaf's
        /// enclosing split axes). The other axis fills its parent, so the
        /// surface may legitimately render beyond the assignment there.
        let exactCols: Bool
        let exactRows: Bool
        /// Why a rendered grid might be absent: whether the pane still has a
        /// panel at all, whether its view sits in a window, and whether the
        /// runtime surface is live.
        let hasPanel: Bool
        let viewInWindow: Bool?
        let surfaceLive: Bool?
        /// Raw device-pixel calibration sample (see
        /// ``TerminalSurfaceRawSizingSample``) — the frame→grid ground truth a
        /// harness fits rendering constants against.
        let calibration: TerminalSurfaceRawSizingSample?
    }

    let windowId: Int
    let panes: [Pane]
    /// The base tree's total assigned cells (tmux's current window size).
    let baseCols: Int
    let baseRows: Int
    /// The last per-window size cmux requested (nil before the first push).
    let pushedColumns: Int?
    let pushedRows: Int?
    let zoomed: Bool
    let structureVersion: Int
    /// Sizing-input introspection: whether this mirror may push (its tab is
    /// visible), the container it last measured, and what the client-size
    /// function computes from that container right now — lets a harness
    /// distinguish "push gate closed" from "push stale" from "geometry
    /// unknown" without screenshots.
    let visibleForSizing: Bool
    let containerPt: CGSize?
    let currentFCols: Int?
    let currentFRows: Int?
}

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
final class RemoteTmuxWindowMirror: RemoteTmuxControlPaneMutationOwner {
    typealias AdoptedPane = (tmuxPaneId: Int, panel: TerminalPanel)

    /// tmux window id (the `@N` without the sigil).
    let windowId: Int
    /// The bonsplit tab's panel id this window renders into.
    let panelId: UUID

    /// Native cmux split/tab chrome for this mirrored tmux window.
    var bonsplitController: BonsplitController

    @ObservationIgnored weak var connection: RemoteTmuxControlConnection?
    @ObservationIgnored weak var workspaceBonsplitController: BonsplitController?
    /// Creates a configured manual-I/O pane panel whose input goes to `tmuxPaneId`.
    @ObservationIgnored let makePanel: (_ tmuxPaneId: Int) -> TerminalPanel?
    @ObservationIgnored var onClosePaneRequest: ((Int) -> Void)?
    /// Session-owned control identity lookup. Render nodes are replaceable.
    @ObservationIgnored private let controlPaneID: (Int) -> PaneID?
    @ObservationIgnored private let onControlSurfaceChanged: ((Int, UUID?) -> Void)?

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
    /// Display title for this mirrored tmux window; every inner surface/tab title
    /// derives from this tmux window name, never from pane-border labels.
    private(set) var windowTitle = String(localized: "remoteTmux.tab.window", defaultValue: "tmux window")

    /// Only the visible tab's mirror writes after its initial claim. Hidden
    /// tabs stay mounted and still receive geometry callbacks, so default-hidden
    /// prevents early surface callbacks from treating an unselected mirror as visible.
    @ObservationIgnored var isVisibleForSizing = false

    /// The flag above, cross-checked against what is actually on screen —
    /// for the settled/mismatch JUDGE, not the sizing gates. The flag alone
    /// goes stale in one direction: tab content is recreated on switch, so a
    /// hidden tab's view can be dismantled without its visibility callback
    /// ever firing, leaving the flag stuck true. Judging that mirror
    /// compares tmux's live assignments against grids nothing renders (its
    /// panes sit in the offscreen parking window) and reports phantom
    /// mismatches. A pane view in a window that is ordered in is the ground
    /// truth for "this mirror's grids are on screen". The sizing gates keep
    /// the plain flag: a stale-true mirror re-claims only its own frozen,
    /// sane size (per-window, deduped), while gating them on view state
    /// would break headless callers that never put panes in a window.
    var isEffectivelyVisibleForSizing: Bool {
        guard isVisibleForSizing else { return false }
        guard let window = panelsByPaneId.values.first?.hostedView.window else {
            return false
        }
        return window.isVisible
    }

    /// ``TerminalPanel`` per tmux pane id. Not observation-tracked: the view
    /// re-reads it whenever ``layout`` (which IS tracked) changes, and the two
    /// are always updated together in ``reconcile(layout:)``.
    @ObservationIgnored var panelsByPaneId: [Int: TerminalPanel] = [:]
    @ObservationIgnored var tabIdByPaneId: [Int: TabID] = [:]
    @ObservationIgnored var paneIdByPaneId: [Int: PaneID] = [:]
    @ObservationIgnored var paneIdByBonsplitPane: [PaneID: Int] = [:]
    @ObservationIgnored var paneIdByTabId: [TabID: Int] = [:]
    @ObservationIgnored var paneIndexByPaneId: [Int: Int] = [:]
    @ObservationIgnored var cwdByPaneId: [Int: String] = [:]
    @ObservationIgnored var isApplyingRemoteLayout = false
    @ObservationIgnored var isApplyingTmuxFocus = false
    @ObservationIgnored var lastDividerPositions: [UUID: CGFloat] = [:]
    /// The (layout, container, metrics) of the last completed imposition
    /// pass — see refreshDividerPositions for why identical inputs skip.
    @ObservationIgnored var lastPlanInputs: (RemoteTmuxLayoutNode, CGSize?, RemoteTmuxNativeLayoutMetrics?)?
    /// Last grid each pane's surface reported (from sizing samples) — the
    /// live half of the settled/mismatch probe.
    @ObservationIgnored var lastRenderedGrids: [Int: (cols: Int, rows: Int)] = [:]

    // MARK: Sizing inputs (locally owned; never tmux-derived)

    /// The mirror container's last-known size in points from `onGeometryChange`.
    @ObservationIgnored var containerSizePt: CGSize?
    /// The hosting window's backing scale, delivered with the container size.
    @ObservationIgnored var containerScale: CGFloat?
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

    /// Whether tmux itself is drawing header rows for this window
    /// (`pane-border-status top`). The strips show label text ONLY then —
    /// a stock tmux displays no titles anywhere, and faithful means matching
    /// that; the active-pane dot is cmux's one addition in both modes.
    private(set) var tmuxTitleRowsVisible = false
    /// Header-strip labels per pane (the expanded `pane-border-format`,
    /// style tokens stripped), copied from the
    /// connection on every reconcile so the view reads stored state, never
    /// the connection. Rendered on the strip above each pane.
    private(set) var paneHeaderLabels: [Int: String] = [:]

    /// The render constants the view actually uses, updated ONLY on event
    /// paths (applied-resize reports, client-size pushes) and read by the
    /// render projection. Keeping the render on a stored snapshot — instead
    /// of querying live surfaces during body evaluation — means view updates
    /// can never observe half-applied surface state, and a snapshot change is
    /// itself the (observable, equality-guarded) signal to re-derive frames.
    private(set) var geometrySnapshot: RemoteTmuxMirrorGeometry?

    /// Injected source of render constants; `nil` measures live surfaces.
    /// Unit tests inject fixed constants here (no live surfaces exist there).
    @ObservationIgnored private let geometrySource: (() -> RemoteTmuxMirrorGeometry?)?

    init(
        windowId: Int,
        panelId: UUID,
        connection: RemoteTmuxControlConnection,
        layout: RemoteTmuxLayoutNode,
        appearance: BonsplitConfiguration.Appearance = .init(),
        workspaceBonsplitController: BonsplitController? = nil,
        geometrySource: (() -> RemoteTmuxMirrorGeometry?)? = nil,
        controlPaneID: @escaping (Int) -> PaneID? = { _ in nil },
        onControlSurfaceChanged: ((Int, UUID?) -> Void)? = nil,
        adoptedPanes: [AdoptedPane] = [],
        makePanel: @escaping (_ tmuxPaneId: Int) -> TerminalPanel?
    ) {
        self.windowId = windowId
        self.panelId = panelId
        self.connection = connection
        self.workspaceBonsplitController = workspaceBonsplitController
        self.makePanel = makePanel
        self.geometrySource = geometrySource
        self.controlPaneID = controlPaneID
        self.onControlSurfaceChanged = onControlSurfaceChanged
        self.layout = layout
        let initialConfiguration = workspaceBonsplitController?.configuration
            ?? BonsplitConfiguration(appearance: appearance)
        self.bonsplitController = Self.makeController(configuration: initialConfiguration)
        configureBonsplitController()
        observeWorkspaceBonsplitConfiguration()
        for pane in adoptedPanes where layout.paneIDsInOrder.contains(pane.tmuxPaneId) {
            panelsByPaneId[pane.tmuxPaneId] = pane.panel
            onControlSurfaceChanged?(pane.tmuxPaneId, pane.panel.id)
            configurePanePanel(pane.panel, paneId: pane.tmuxPaneId, needsSeed: false)
        }
        reconcile(layout: layout)
    }

    /// All tmux pane ids currently in the window, depth-first left→right.
    var paneIDsInOrder: [Int] { layout.paneIDsInOrder }

    /// The panel rendering `tmuxPaneId`, if it exists.
    func panel(forPane tmuxPaneId: Int) -> TerminalPanel? { panelsByPaneId[tmuxPaneId] }

    /// The surface rendering `tmuxPaneId`, if it exists.
    func surface(forPane tmuxPaneId: Int) -> TerminalSurface? { panelsByPaneId[tmuxPaneId]?.surface }

    /// The session-owned stable control pane id for `tmuxPaneId`.
    func syntheticPaneID(forPane tmuxPaneId: Int) -> PaneID? {
        controlPaneID(tmuxPaneId)
    }

    /// Applies a full window update: panel lifecycle + sizing structure from
    /// the BASE tree, rendering tree from the VISIBLE one. Zoom therefore
    /// never creates or closes panels, and f's output is zoom-invariant.
    func apply(window: RemoteTmuxWindow) {
        let previousRenderedLayout = renderedLayout
        let nextTitle = RemoteTmuxSessionMirror.tabTitle(for: window)
        if windowTitle != nextTitle { windowTitle = nextTitle }
        let newVisible = window.zoomed ? window.visibleLayout : nil
        if visibleLayout != newVisible { visibleLayout = newVisible }
        if zoomed != window.zoomed { zoomed = window.zoomed }
        reconcile(layout: window.layout, previousRenderedLayout: previousRenderedLayout)
    }

    /// Updates the base layout, creating panels for new panes and tearing down
    /// panels for panes tmux removed (surviving panes keep their panel and
    /// scrollback).
    func reconcile(layout newLayout: RemoteTmuxLayoutNode) {
        reconcile(layout: newLayout, previousRenderedLayout: renderedLayout)
    }

    private func reconcile(
        layout newLayout: RemoteTmuxLayoutNode,
        previousRenderedLayout: RemoteTmuxLayoutNode
    ) {
        let livePaneIDsInOrder = newLayout.paneIDsInOrder
        let livePaneIds = Set(livePaneIDsInOrder)
        paneIndexByPaneId = Dictionary(
            livePaneIDsInOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { firstIndex, _ in firstIndex }
        )
        for paneId in livePaneIDsInOrder where panelsByPaneId[paneId] == nil {
            guard let panel = makePanel(paneId) else { continue }
            panelsByPaneId[paneId] = panel
            onControlSurfaceChanged?(paneId, panel.id)
            configurePanePanel(panel, paneId: paneId, needsSeed: true)
        }
        for (paneId, panel) in panelsByPaneId where !livePaneIds.contains(paneId) {
            // Use the full panel close (detaches the portal from the registry
            // BEFORE freeing the surface) so a stale portal entry can't be
            // dereferenced by a later Core Animation commit.
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
            onControlSurfaceChanged?(paneId, nil)
            panel.close()
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
            connection?.unsubscribePaneHeader(paneId: paneId)
            panelsByPaneId[paneId] = nil
            cwdByPaneId[paneId] = nil
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
        let labels = (connection?.paneHeaderLabels ?? [:]).filter { livePaneIds.contains($0.key) }
        if labels != paneHeaderLabels { paneHeaderLabels = labels }
        let titleRows = connection?.windowTitleRowsVisible[windowId] ?? false
        if tmuxTitleRowsVisible != titleRows {
            tmuxTitleRowsVisible = titleRows
            // Title rows are part of the claim's chrome (one cell per pane
            // when active): flipping pane-border-status changes how many
            // rows fit, so the claim must re-push, not just the dividers.
            _ = updateClientSize()
        }
        reconcileBonsplitTree(from: previousRenderedLayout, to: renderedLayout)
        // Adopt tmux's known active pane when this mirror has none yet: on
        // first attach the rects reply emits the active-pane event BEFORE the
        // topology publish creates this mirror, so the event-driven path
        // (noteRemoteActivePane) can't have delivered it.
        if activePaneId == nil,
           let remoteActive = connection?.activePaneByWindow[windowId],
           livePaneIds.contains(remoteActive) {
            setActivePane(remoteActive, fromTmux: true)
        } else {
            seedActivePaneIfNeeded()
        }
        refreshPaneTitles()
        // Drive the ONE-TIME claim from topology publishes too, not just view
        // geometry and surface reports. Without this a hidden window can
        // deadlock unclaimed: the claim needs a calibration sample, a sample
        // needs a surface resize, and tmux only resizes the window once it is
        // claimed — while topology publishes (the one event an attaching
        // session always keeps producing) sweep live samples and break the
        // cycle. Echo-safe: once claimed this never runs again, and f reads
        // no tmux geometry, so a reconcile-triggered push recomputes the
        // identical size and dedups.
        if let connection, connection.lastWindowSizes[windowId] == nil {
            updateClientSize()
        }
    }

    private func configurePanePanel(_ panel: TerminalPanel, paneId: Int, needsSeed: Bool) {
        let surface = panel.surface
        surface.onManualSizeApplied = { [weak self] in
            self?.handleSizingSample($0, paneId: paneId)
        }
        surface.onRuntimeReady = { [weak self, weak surface] in
            guard let sample = surface?.rawSizingSample() else { return }
            self?.handleSizingSample(sample, paneId: paneId)
        }
        surface.flushPendingManualSizeReportIfAttached()
        if let sample = surface.rawSizingSample() {
            handleSizingSample(sample, paneId: paneId)
        }
        if needsSeed { connection?.seedPane(paneId: paneId) }
    }

    /// Routes a tmux `%output` to the surface for `paneId` (no-op if unknown).
    func routeOutput(paneId: Int, data: Data) {
        panelsByPaneId[paneId]?.surface.processRemoteOutput(data)
    }

    /// Records the container's size (points) and backing scale — f's variable
    /// inputs, delivered by the view on mount and every geometry change.
    ///
    /// A size change also re-imposes the divider plan: rail fractions are a
    /// function of the container (``RemoteTmuxNativeSplitLayout``), so a
    /// resize that stays inside one claim bucket — same claim, no
    /// `%layout-change` echo, no reconcile — would otherwise leave the tree
    /// scaling stale fractions proportionally, and a lopsided split can
    /// lose more than the pane slack and wrap. The old ideal-over-ideal
    /// fractions were container-independent, so no trigger existed here.
    func noteContainerSize(pointSize: CGSize, scale: CGFloat) {
        // Hidden tabs keep their last visible geometry. A hidden tab's
        // portal-hosted views have no window clamping them, so their
        // reported bounds are not the size anything renders at — and once
        // impositions inflate a hidden host (see refreshDividerPositions),
        // recording those bounds would poison the claim tmux hears when a
        // reconnect lets every window claim again. The one exception is the
        // very first measurement: a never-shown mirror must still record
        // its attach-time size so the initial claim can keep tmux off its
        // 80×24 default.
        guard isVisibleForSizing || containerSizePt == nil else { return }
        // Nothing larger than the hosting window can be displayed, so no
        // honest container is larger either. SwiftUI can hand this callback
        // a content-derived size when some ancestor adopts a layout ideal —
        // and recording it would feed the claim, grow tmux's assignments,
        // grow the layout, and hand back a bigger size next pass, without
        // bound. Clamping at this boundary breaks that loop no matter which
        // view leaks an ideal.
        var pointSize = pointSize
        if let window = panelsByPaneId.values.first?.hostedView.window,
           window.isVisible {
            let bound = window.contentLayoutRect.size
            if bound.width > 1, bound.height > 1 {
                pointSize.width = min(pointSize.width, bound.width)
                pointSize.height = min(pointSize.height, bound.height)
            }
        } else if containerSizePt != nil {
            // No visible window to validate against means the panes are
            // parked (portal limbo) and this callback's size is not
            // evidence of anything on screen — recording it is how limbo
            // geometry reached the claim. Only the very first measurement
            // may pass unvalidated: it is the attach-time size the initial
            // claim needs, delivered before the panes enter a window.
            return
        }
        #if DEBUG
        if pointSize.width > 3000 || pointSize.height > 3000 {
            let window = panelsByPaneId.values.first?.hostedView.window
            cmuxDebugLog(
                "remote.container.record @\(windowId)"
                    + " size=\(Int(pointSize.width))x\(Int(pointSize.height))"
                    + " panels=\(panelsByPaneId.count)"
                    + " win=\(window.map { "\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height)) vis=\($0.isVisible ? 1 : 0) cls=\(String(describing: type(of: $0)))" } ?? "nil")"
            )
        }
        #endif
        let sizeChanged = containerSizePt != pointSize
        containerSizePt = pointSize
        containerScale = scale
        if sizeChanged {
            refreshDividerPositions()
        }
    }

    /// Ingests one sizing sample into the min-tracked pad constants.
    private func ingest(sample: TerminalSurfaceRawSizingSample) {
        guard sample.cellWidthPx > 0, sample.cellHeightPx > 0,
              sample.columns > 1, sample.rows > 1,
              let scale = sample.backingScale ?? containerScale, scale > 0
        else { return }
        let nonGridW = sample.surfaceWidthPx - sample.columns * sample.cellWidthPx
        let nonGridH = sample.surfaceHeightPx - sample.rows * sample.cellHeightPx
        if nonGridW >= 0 {
            minNonGridWidthPxByScale[scale] = min(minNonGridWidthPxByScale[scale] ?? nonGridW, nonGridW)
        }
        if nonGridH >= 0 {
            minNonGridHeightPxByScale[scale] = min(minNonGridHeightPxByScale[scale] ?? nonGridH, nonGridH)
        }
        let geometry = RemoteTmuxMirrorGeometry(
            cellWidthPx: sample.cellWidthPx,
            cellHeightPx: sample.cellHeightPx,
            surfacePadWidthPx: minNonGridWidthPxByScale[scale] ?? max(0, nonGridW),
            surfacePadHeightPx: minNonGridHeightPxByScale[scale] ?? max(0, nonGridH),
            scale: scale
        )
        if geometrySnapshot != geometry {
            geometrySnapshot = geometry
            // The first measured cell size, and later scale/font changes, alter
            // the exact native fraction that represents tmux's cell geometry.
            refreshDividerPositions()
        }
    }

    private func handleSizingSample(_ sample: TerminalSurfaceRawSizingSample, paneId: Int) {
        ingest(sample: sample)
        lastRenderedGrids[paneId] = (cols: sample.columns, rows: sample.rows)
        #if DEBUG
        // The one line that makes "tests green, screen wrong" a grep instead
        // of a debugging session: whenever a surface settles on a grid that
        // disagrees with the span tmux assigned its pane, say so. Rendering
        // FEWER columns than assigned wraps every full-width line.
        if let leaf = renderedLayout.firstLeaf(withPaneId: paneId),
           sample.columns < leaf.width || sample.rows < leaf.height {
            cmuxDebugLog(
                "remote.grid.mismatch @\(windowId) pane=%\(paneId)"
                    + " rendered=\(sample.columns)x\(sample.rows)"
                    + " assigned=\(leaf.width)x\(leaf.height)"
            )
        }
        #endif
        _ = updateClientSize()
    }

    /// Sweeps every pane's current sizing sample through ``ingest(sample:)``
    /// — the push path's calibration refresh for triggers that don't carry a
    /// sample of their own (container changes, structure changes).
    private func refreshGeometryConstants() {
        for panel in panelsByPaneId.values {
            guard let sample = panel.surface.rawSizingSample() else { continue }
            ingest(sample: sample)
        }
    }

    /// The measured render constants, or nil while no sample has arrived
    /// yet. A pure read of the stored snapshot (or the injected test
    /// source), safe from view-body projection (`framesForRender`): the
    /// render never touches live surfaces, so it can't observe half-applied
    /// resize state.
    func currentGeometry() -> RemoteTmuxMirrorGeometry? {
        if let geometrySource { return geometrySource() }
        return geometrySnapshot
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
        #if DEBUG
        cmuxDebugLog(
            "remote.rects.push @\(windowId) container="
                + (containerSizePt.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")
                + " scale=\(containerScale ?? 0) geom=\(currentGeometry() != nil ? 1 : 0)"
                + " visible=\(isVisibleForSizing ? 1 : 0) panels=\(panelsByPaneId.count)"
        )
        #endif
        guard let containerSizePt, containerScale != nil,
              containerSizePt.width > 1, containerSizePt.height > 1,
              let cells = clientGrid(contentSize: containerSizePt)
        else { return false }
        connection.setWindowSize(
            windowId: windowId,
            columns: cells.columns,
            rows: cells.rows
        )
        return true
    }

    /// The exact frames to impose for the current tmux layout, or `nil` when the
    /// render should fall back to the proportional TRANSIENT mode: constants
    /// still unknown, or tmux's layout doesn't match what f wants for the current
    /// pixels (a push is in flight — drag mid-motion, attach settling, or a
    /// co-attached client constraining the size). The transient mode always
    /// fits by construction; imposition resumes on tmux's layout that matches.
    func framesForRender(containerPt: CGSize) -> RemoteTmuxMirrorFrames? {
        guard let geometry = currentGeometry(),
              let cells = clientGrid(contentSize: containerPt),
              layout.width == cells.columns,
              layout.height == cells.rows else { return nil }
        return geometry.frames(layout: visibleLayout ?? layout, containerPt: containerPt)
    }

    /// Records tmux's active pane as reported by the remote
    /// (`%window-pane-changed` or the rects fetch) — the strip dot follows
    /// tmux truth, not local focus alone. Tolerates unknown panes: the
    /// matching layout may still be pending its rects publication.
    func noteRemoteActivePane(_ paneId: Int) {
        if activePaneId != paneId { activePaneId = paneId }
        focusBonsplitPane(forTmuxPane: paneId)
    }

    func setActivePane(_ paneId: Int, fromTmux: Bool) {
        guard layout.paneIDsInOrder.contains(paneId) else { return }
        if activePaneId != paneId { activePaneId = paneId }
        focusBonsplitPane(forTmuxPane: paneId)
        if !fromTmux {
            connection?.send("select-pane -t @\(windowId).%\(paneId)")
        }
    }

    /// Records the user-focused pane and asks tmux to make it active.
    func focus(pane tmuxPaneId: Int) {
        setActivePane(tmuxPaneId, fromTmux: false)
    }

    /// Routes an accepted control-plane mutation through the owned connection.
    func sendControlCommand(_ command: String) -> Bool {
        connection?.send(command) ?? false
    }

    func connectionSendKeys(paneID: Int, data: Data) -> Bool {
        connection?.sendKeys(paneId: paneID, data: data) ?? false
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

    /// Tears down every pane panel (called when the window-tab is removed).
    func teardown() {
        workspaceBonsplitController = nil
        // Unsubscribe each pane's cwd subscription first — matching reconcile(layout:),
        // which unsubscribes per removed pane. Without this, a control connection that
        // outlives the tab keeps streaming pane_current_path updates into a dead mirror.
        for paneId in panelsByPaneId.keys {
            connection?.unsubscribePanePath(paneId: paneId)
            connection?.unsubscribePaneReflow(paneId: paneId)
            connection?.unsubscribePaneHeader(paneId: paneId)
        }
        for (paneId, panel) in panelsByPaneId {
            panel.surface.onManualSizeApplied = nil
            panel.surface.onRuntimeReady = nil
            onControlSurfaceChanged?(paneId, nil)
            panel.close()
        }
        panelsByPaneId.removeAll()
        tabIdByPaneId.removeAll()
        paneIdByPaneId.removeAll()
        paneIdByBonsplitPane.removeAll()
        paneIdByTabId.removeAll()
        cwdByPaneId.removeAll()
        activePaneId = nil
    }
}

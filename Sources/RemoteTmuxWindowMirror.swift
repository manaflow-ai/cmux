import CmuxRemoteSession
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
/// STRUCTURE, and measured render constants — never of tmux-assigned geometry
/// or rendered grids. The render side sets bonsplit divider fractions from
/// tmux's assigned cells (``RemoteTmuxNativeSplitLayoutPlanner`` via
/// ``imposeDividerPlan()``, driven by the sizing pass). Neither
/// direction measures the other back,
/// so tmux's `%layout-change` echo of our own push recomputes to the identical
/// size and dedups to silence: there is no feedback loop to gate, budget, or
/// pin against. Pane ratios are user state and are never written.
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
    /// Establishes keyboard (first-responder) focus for a pane the mirror just
    /// created and made active. A freshly split pane is born active and visible
    /// inside an already-visible tab, so neither the surface's active nor its
    /// visibility false→true edge fires — the pane shows the selection highlight
    /// but owns no key focus until clicked. This drives the same first-responder
    /// establishment a click does, on the creation event edge. `nil` in headless
    /// and direct-construction callers. Set after construction so it can capture
    /// the mirror weakly (see ``RemoteTmuxSessionMirror``).
    @ObservationIgnored var onEstablishPaneKeyFocus: ((_ tmuxPaneId: Int, _ panel: TerminalPanel) -> Void)?
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
    /// Terminal teardown is final. Run-loop-coalesced sizing callbacks may
    /// still hold this mirror until the next turn, so they must observe an
    /// explicit lifecycle edge before touching the shared connection again.
    @ObservationIgnored var isTornDown = false

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
        guard !isTornDown, isVisibleForSizing else { return false }
        return panelsByPaneId.values.contains { panel in
            let hostedView = panel.hostedView
            return hostedView.isVisibleInUI
                && !hostedView.isHidden
                && hostedView.superview != nil
                && hostedView.window?.isVisible == true
        }
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
    /// Panes whose panel this mirror just created and which have not yet had
    /// key focus established. A member is consumed the first time it becomes the
    /// active pane, so exactly one creation drives key focus — never a later
    /// active-pane echo or a co-attached client's pane switch.
    @ObservationIgnored private var panesAwaitingCreationFocus: Set<Int> = []
    /// Bumped on every active-pane transition, including to `nil`. A pending
    /// creation-focus intent captures this when it arms; any intervening
    /// transition — even one that returns to the same pane (N→O→N) —
    /// invalidates the intent, so an attach hook that fires later can never
    /// replay a stale activation as a focus steal.
    @ObservationIgnored private(set) var paneActivationGeneration: UInt64 = 0
    @ObservationIgnored var isApplyingRemoteLayout = false
    @ObservationIgnored var isApplyingTmuxFocus = false
    @ObservationIgnored var lastDividerPositions: [UUID: CGFloat] = [:]
    /// Last grid each pane's surface reported (from sizing samples) — the
    /// live half of the settled/mismatch probe.
    @ObservationIgnored var lastRenderedGrids: [Int: (cols: Int, rows: Int)] = [:]

    // MARK: Sizing inputs (locally owned; never tmux-derived)

    /// The mirror container's last-known size in points from `onGeometryChange`.
    @ObservationIgnored var containerSizePt: CGSize?
    /// The hosting window's backing scale, delivered with the container size.
    @ObservationIgnored var containerScale: CGFloat?
    /// Latest post-claim geometry received before any pane has a visible host.
    /// It is not sizing truth until a hosting window bounds it.
    @ObservationIgnored var pendingContainerSizePt: CGSize?
    @ObservationIgnored var pendingContainerScale: CGFloat?
    /// The latest reading the hosting window's bound rejected as oversized.
    /// The verdict itself can be wrong: during an AppKit resize the reading
    /// may be post-resize truth while the bound is the transient old frame.
    /// The next sizing pass re-judges it once against that pass's bound —
    /// banked if it fits, discarded for good if it still exceeds it. Never
    /// merged with `pendingContainerSizePt`: pending consumption clamps to
    /// the bound, and clamping a genuinely oversized reading would bank the
    /// bound itself, the exact poison the drop path exists to prevent.
    @ObservationIgnored var pendingOversizedReading: (size: CGSize, scale: CGFloat)?
    /// An NSView planted inside the mirror's own view subtree (not the portal
    /// layer), so `hostProbeView?.window` is the hosting window even while
    /// portal-hosted panels churn, and its superview chain is the real
    /// ancestor stack that produced the SwiftUI proposal.
    @ObservationIgnored weak var hostProbeView: NSView?
    /// Set when the divider sync sends a resize-pane between a drag session's
    /// begin and end. Bonsplit delivers the final drag geometry notification
    /// just BEFORE drag-end (the delegate contract: settled geometry is
    /// already reported when drag-end runs), so the drag-end re-sync usually
    /// finds the baseline already advanced and sends nothing — this flag
    /// keeps that from reading as "the drag changed no cells".
    @ObservationIgnored var dividerResizeSentSinceDragBegan = false
    /// The one divider resize-pane in flight, keyed by the split it was sent
    /// for and the span it asked of tmux. The round trip is a known-stale-
    /// plan window: the tree holds the user's dragged fraction while
    /// lastPlannedOuterSizes holds the pre-drag plan, so the output-parity
    /// re-arm would read the dragged views as an apply miss and re-impose
    /// the stale plan — the divider visibly bounced back, then jumped when
    /// tmux's reply landed. While a send is in flight the re-arm holds, and
    /// impositions skip the held split (an UNRELATED layout change replans
    /// from a tree that is equally pre-drag for that split).
    ///
    /// Every release edge is a protocol or geometry event — never time:
    ///  - a reconciled layout assigns the sent span (the reply landed), or
    ///    the split disappears (structure changed under it);
    ///  - tmux answers the resize with `%error` — recovery immediately;
    ///  - the resize's own ack arrives, then a barrier command's ack arrives
    ///    with no intervening layout event for this window: control mode
    ///    orders reply blocks and notifications on one stream, and a
    ///    `%layout-change` a command causes is emitted after that command's
    ///    `%end` but before any block for a command sent later — so a
    ///    barrier issued at the resize's ack and answered without a layout
    ///    event PROVES the send was a no-op (a span tmux's cascade minimums
    ///    clamped to nothing). Recovery re-imposes the plan and parity
    ///    resumes judging (see `sendDividerResize` in
    ///    RemoteTmuxWindowMirror+DividerSizing.swift);
    ///  - the barrier's ack found this window's layout fetch still in
    ///    flight: the publication (or its drop — both resolve the pending
    ///    layout) makes the final judgment in `reconcile`;
    ///  - the stream resets before any of the above: the tracked completion
    ///    fails and recovery runs, with the reconnect republishing truth.
    /// Generation-checked throughout: a newer send supersedes an older
    /// send's pending acks and barrier.
    struct DividerResizeInFlight {
        let generation: UInt64
        let splitId: UUID
        let axis: RemoteTmuxSplitOrientation
        let targetCells: Int
        /// Set when the barrier ack found a pending (unpublished) layout for
        /// this window: the resolution of that fetch is the final verdict.
        var barrierAcked = false
    }
    @ObservationIgnored var dividerResizeInFlight: DividerResizeInFlight?
    @ObservationIgnored var dividerResizeInFlightGeneration: UInt64 = 0
    /// The exact point size the split tree renders at (grid + chrome), set by
    /// the sizing pass; the view frames the tree to this, top-leading, so the
    /// region's sub-cell remainder stays outside the tree. nil until the
    /// first sized pass (the view fills the region as before).
    var renderFrameSize: CGSize?
    /// Monotone minimum of `surface_px − cols·cell_px` observed per axis: the
    /// ghostty padding estimate, KEYED BY BACKING SCALE. A single sample
    /// overestimates padding by the quantization remainder (< one cell),
    /// which only makes f conservative by at most one column; the minimum
    /// converges to the true padding within a few distinct sizes and never
    /// grows. Padding is a device-pixel constant PER SCALE (8px at 2×, ~4px
    /// at 1×): mixing samples across a 1×↔2× display move would drag the 2×
    /// minimum permanently below truth and overshoot f by a column.
    @ObservationIgnored var minNonGridWidthPxByScale: [CGFloat: Int] = [:]
    @ObservationIgnored var minNonGridHeightPxByScale: [CGFloat: Int] = [:]

    /// The edge where tmux draws pane-title rows, or nil when they are off.
    private(set) var tmuxTitleRowPlacement: RemoteTmuxPaneTitleRowPlacement?
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
    var geometrySnapshot: RemoteTmuxMirrorGeometry?

    /// Injected source of render constants; `nil` measures live surfaces.
    /// Unit tests inject fixed constants here (no live surfaces exist there).
    @ObservationIgnored let geometrySource: (() -> RemoteTmuxMirrorGeometry?)?
    /// Injected hosting-window bound; `nil` resolves it from live pane views.
    @ObservationIgnored let hostingContentSizeSource: (() -> CGSize?)?

    /// Everything a sizing pass depends on, snapshotted for the fixed-point
    /// check. When a completed pass's inputs equal the current inputs, the
    /// mirror is settled and a pass would be a no-op.
    struct SizingInputs: Equatable {
        /// Base and visible trees are fingerprinted SEPARATELY: the claim
        /// reads the BASE tree (its residual depends on the full tree even
        /// while zoomed), and the plan reads the visible one. Fingerprinting
        /// only their merge let a base-tree change hide behind an unchanged
        /// visible tree — the pass skipped, the claim went stale, and tmux
        /// kept an old size through a whole settle window.
        var baseLayout: RemoteTmuxLayoutNode
        var visibleLayout: RemoteTmuxLayoutNode?
        var container: CGSize?
        var scale: CGFloat?
        var geometry: RemoteTmuxMirrorGeometry?
        var titleRowPlacement: RemoteTmuxPaneTitleRowPlacement?
        var visible: Bool
    }

    /// Identifies whether a sizing pass follows new inputs or must reapply refused constraints.
    enum SizingPassIntent {
        case inputChange
        case constraintRecovery
    }

    @ObservationIgnored var sizingPassScheduled = false
    @ObservationIgnored var lastCompletedSizingInputs: SizingInputs?
    @ObservationIgnored var pendingSizingPassIntent = SizingPassIntent.inputChange

    /// The per-pane outer sizes the last imposition granted — the plan side
    /// of the output-parity check in `rearmIfOutputMissedPlan()` and of the
    /// chrome-parity probe in ``handleSizingSample``.
    @ObservationIgnored var lastPlannedOuterSizes: [Int: CGSize] = [:]
    /// Output-parity re-arm state: how many bounded recovery passes this
    /// input fixed point has spent, and which fixed point they belong to
    /// (the counter resets when the completed inputs change). Tracked apart
    /// from `lastCompletedSizingInputs` because a re-arm nils that field —
    /// folding the two together would reset the counter on every re-arm and
    /// unbound the loop.
    @ObservationIgnored var outputParityRearmsSpent = 0
    @ObservationIgnored var outputParityRearmInputs: SizingInputs?
    @ObservationIgnored var outputParityCheckScheduled = false

    #if DEBUG
    /// One ancestor-chain dump per window: `dumpProposalAncestors` fires per
    /// dropped container reading, and one chain names the leaking subtree.
    @ObservationIgnored var dumpedAncestorChains = false
    #endif

    init(
        windowId: Int,
        panelId: UUID,
        connection: RemoteTmuxControlConnection,
        layout: RemoteTmuxLayoutNode,
        appearance: BonsplitConfiguration.Appearance = .init(),
        workspaceBonsplitController: BonsplitController? = nil,
        geometrySource: (() -> RemoteTmuxMirrorGeometry?)? = nil,
        hostingContentSizeSource: (() -> CGSize?)? = nil,
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
        self.hostingContentSizeSource = hostingContentSizeSource
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
            panesAwaitingCreationFocus.insert(paneId)
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
            panesAwaitingCreationFocus.remove(paneId)
            if activePaneId == paneId { recordActivePane(nil) }
        }
        lastRenderedGrids = lastRenderedGrids.filter { livePaneIds.contains($0.key) }
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
        let titleRowPlacement = connection?.windowTitleRowPlacements[windowId]
        if tmuxTitleRowPlacement != titleRowPlacement {
            tmuxTitleRowPlacement = titleRowPlacement
        }
        reconcileBonsplitTree(from: previousRenderedLayout, to: renderedLayout)
        // Pin every pane's grid to the fresh assignment HERE, not only in
        // the sizing pass: the pass is visibility-gated, so a hidden
        // window's pins would otherwise freeze at its last-visible
        // assignment while tmux moves on, and the pinned grid would drag
        // the mirror to a stale tree. Ingestion runs for every published
        // layout, visible or not, and the pin touches only surface pixels.
        applyAssignedGrids()
        // A barrier-acked divider hold deferred its verdict to this window's
        // layout fetch; once the connection holds no pending layout the fetch
        // has resolved (published — this reconcile — or dropped keeping the
        // verified tree), and the current tree is the final answer for the
        // sent span. Judge before scheduling the pass so a released hold no
        // longer skips its split.
        if dividerResizeInFlight?.barrierAcked == true,
           connection?.hasPendingLayout(windowId: windowId) != true {
            judgeDividerResizeHold()
        }
        setNeedsSizingPass()
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

    /// (`%window-pane-changed` or the rects fetch) — the strip dot follows
    /// tmux truth, not local focus alone. Tolerates unknown panes: the
    /// matching layout may still be pending its rects publication.
    func noteRemoteActivePane(_ paneId: Int) {
        recordActivePane(paneId)
        focusBonsplitPane(forTmuxPane: paneId)
        establishCreationKeyFocusIfPending(forPane: paneId)
    }

    func setActivePane(_ paneId: Int, fromTmux: Bool) {
        guard layout.paneIDsInOrder.contains(paneId) else { return }
        recordActivePane(paneId)
        focusBonsplitPane(forTmuxPane: paneId)
        if !fromTmux {
            connection?.send("select-pane -t @\(windowId).%\(paneId)")
        }
        establishCreationKeyFocusIfPending(forPane: paneId)
    }

    /// Drives keyboard (first-responder) focus onto a pane the moment it first
    /// becomes active after this mirror created it. A freshly split pane is born
    /// active and visible inside an already-visible tab, so the surface's own
    /// active/visibility false→true edges never fire the first-responder apply,
    /// and — because a mirror pane panel is not a workspace Bonsplit tab — the
    /// workspace focus path cannot resolve it either. The result is the reported
    /// bug: the new pane is highlighted but takes no keys until clicked. Consume
    /// the creation marker so this runs once per created pane, never on a later
    /// active-pane echo or a co-attached client's pane switch.
    private func establishCreationKeyFocusIfPending(forPane paneId: Int) {
        guard panesAwaitingCreationFocus.contains(paneId),
              let panel = panelsByPaneId[paneId] else { return }
        panesAwaitingCreationFocus.remove(paneId)
        onEstablishPaneKeyFocus?(paneId, panel)
    }

    /// Records an active-pane transition; every change bumps the activation
    /// generation that pending creation-focus intents are validated against.
    private func recordActivePane(_ paneId: Int?) {
        guard activePaneId != paneId else { return }
        activePaneId = paneId
        paneActivationGeneration &+= 1
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
        guard !isTornDown else { return }
        isTornDown = true
        isVisibleForSizing = false
        sizingPassScheduled = false
        lastCompletedSizingInputs = nil
        pendingSizingPassIntent = .inputChange
        pendingContainerSizePt = nil
        pendingContainerScale = nil
        pendingOversizedReading = nil
        dividerResizeInFlight = nil
        let activeConnection = connection
        activeConnection?.removeWindowSizeClaim(windowId: windowId)
        workspaceBonsplitController = nil
        // Unsubscribe each pane's cwd subscription first — matching reconcile(layout:),
        // which unsubscribes per removed pane. Without this, a control connection that
        // outlives the tab keeps streaming pane_current_path updates into a dead mirror.
        for paneId in panelsByPaneId.keys {
            activeConnection?.unsubscribePanePath(paneId: paneId)
            activeConnection?.unsubscribePaneReflow(paneId: paneId)
            activeConnection?.unsubscribePaneHeader(paneId: paneId)
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
        panesAwaitingCreationFocus.removeAll()
        lastRenderedGrids.removeAll()
        recordActivePane(nil)
        connection = nil
    }

    /// What to do with a freshly created pane's key focus, given the state the
    /// guards can see. Pure so the policy is pinned by a truth table without a
    /// live window (``RemoteTmuxMirrorPaneKeyFocusDecisionTests``).
    enum PaneKeyFocusDecision: Equatable {
        /// The view is mounted in a visible key window, the pane is still the
        /// one the user just created and made active, and the responder chain
        /// still belongs to the terminal layer: focus it now.
        case focusNow
        /// Everything still holds but the view has not reached a presentation
        /// window — it is unattached, or attached to the surface's offscreen
        /// bootstrap/parking window. Both states end in another
        /// `viewDidMoveToWindow` (the parking window is never where a pane is
        /// presented), so (re-)arm the attach hook and decide again on that
        /// edge. No timer; an intent whose pane never gets presented dies on
        /// the pane-switch or teardown guards instead.
        case waitForMount
        /// The intent is dead: the pane is no longer the active one, the
        /// mirror is gone or off screen, the view's final attachment is in a
        /// hidden or non-key window (which has no attach edge to wait on), or
        /// the user has since focused a non-terminal responder (a search
        /// field, a palette). Focus stays where it is — never steal it,
        /// never hold a stale intent.
        case skip
    }

    /// The guard set every focus attempt shares (at the creation event, and
    /// again on each attach edge). Only pre-presentation states wait — they
    /// have an exact edge (`viewDidMoveToWindow` fires again when the view
    /// leaves the parking window for its presentation window). Everything
    /// else either focuses or cancels: a real window that is hidden or not
    /// key has no wakeup edge, so retaining the intent would risk a stale
    /// focus steal later.
    static func paneKeyFocusDecision(
        mirrorAlive: Bool,
        paneStillActive: Bool,
        mirrorOnScreen: Bool,
        viewInWindow: Bool,
        inParkingWindow: Bool,
        viewVisibleInUI: Bool,
        windowIsKey: Bool,
        responderYields: Bool
    ) -> PaneKeyFocusDecision {
        guard mirrorAlive, paneStillActive, mirrorOnScreen else { return .skip }
        guard viewInWindow, !inParkingWindow else { return .waitForMount }
        guard viewVisibleInUI, windowIsKey, responderYields else { return .skip }
        return .focusNow
    }

    /// Establishes key focus on a freshly created pane the way a click does —
    /// `moveFocus()` makes the pane surface the window's first responder directly,
    /// since a mirror pane surface is not a workspace Bonsplit tab and so cannot
    /// travel the guarded `applyFirstResponderIfNeeded` path. The seam fires from
    /// the control-stream event that makes the pane active, which can land before
    /// SwiftUI has mounted the pane's hosted view; in that case the view's own
    /// attach edge (`onDidAttachToWindow`, consumed once per fire from
    /// `viewDidMoveToWindow`) re-runs the decision — no timer, no retry. An
    /// attach that lands in the surface's offscreen bootstrap/parking window
    /// re-arms the hook: leaving that window for the presentation window is
    /// itself another attach edge.
    ///
    /// Every attempt re-checks the mirror is still on screen and this pane is
    /// still its active pane on the SAME activation that armed the intent — an
    /// activation generation captured at arm time invalidates the intent on
    /// any intervening pane switch, even one that returns to this pane
    /// (N→O→N), so a hook that fires later can never replay a stale
    /// activation. The user focusing a non-terminal responder such as a
    /// search field also cancels, since a late mount must not pull focus out
    /// of it. A mirror whose panes land in a hidden or non-key window — a
    /// background tab, or any headless caller — never moves the first
    /// responder and never keeps the intent alive. If the view never mounts,
    /// the armed hook is simply never called and focus stays where it was.
    static func establishPaneKeyFocusWhenMounted(
        paneId: Int,
        panel: TerminalPanel,
        mirror: RemoteTmuxWindowMirror?
    ) {
        attemptPaneKeyFocus(
            paneId: paneId,
            panel: panel,
            mirror: mirror,
            armedGeneration: mirror?.paneActivationGeneration ?? 0
        )
    }

    private static func attemptPaneKeyFocus(
        paneId: Int,
        panel: TerminalPanel,
        mirror: RemoteTmuxWindowMirror?,
        armedGeneration: UInt64
    ) {
        let hostedView = panel.hostedView
        switch paneKeyFocusDecision(
            paneId: paneId,
            hostedView: hostedView,
            mirror: mirror,
            armedGeneration: armedGeneration
        ) {
        case .focusNow:
            hostedView.moveFocus()
        case .waitForMount:
            hostedView.onDidAttachToWindow = { [weak mirror, weak panel] in
                // One hop off the view-insertion/layout pass that delivered
                // `viewDidMoveToWindow`; mutating the first responder inside it
                // is unsafe. This is a re-entrancy guard, not a wait.
                Task { @MainActor in
                    guard let panel else { return }
                    attemptPaneKeyFocus(
                        paneId: paneId,
                        panel: panel,
                        mirror: mirror,
                        armedGeneration: armedGeneration
                    )
                }
            }
        case .skip:
            break
        }
    }

    private static func paneKeyFocusDecision(
        paneId: Int,
        hostedView: GhosttySurfaceScrollView,
        mirror: RemoteTmuxWindowMirror?,
        armedGeneration: UInt64
    ) -> PaneKeyFocusDecision {
        // Mount state reads the view's OWN window — the state
        // `viewDidMoveToWindow` reports on. `uiWindow` differs from it in
        // exactly one case: the attach landed in the surface's offscreen
        // bootstrap/parking window, which `TerminalSurface.uiWindow` filters
        // to nil. That case must wait (the presentation reattach is another
        // attach edge), not consume the intent.
        let window = hostedView.window
        return paneKeyFocusDecision(
            mirrorAlive: mirror.map { !$0.isTornDown } ?? false,
            paneStillActive: mirror?.activePaneId == paneId
                && mirror?.paneActivationGeneration == armedGeneration,
            mirrorOnScreen: mirror?.isEffectivelyVisibleForSizing == true,
            viewInWindow: window != nil,
            inParkingWindow: window != nil && hostedView.uiWindow == nil,
            viewVisibleInUI: hostedView.isVisibleInUI,
            windowIsKey: window?.isKeyWindow == true,
            responderYields: window.map { responderYieldsToPaneFocus($0.firstResponder) } ?? true
        )
    }

    /// Whether the window's current first responder belongs to the terminal
    /// content layer — nothing, the window itself, or a responder owned by a
    /// terminal surface view (``cmuxOwningGhosttyView(for:)``, which also
    /// resolves field editors to their owner). Anything else — a search
    /// field's editor, a palette, a sidebar text view — means the user has
    /// since put focus somewhere deliberate, and the pending creation focus
    /// must cancel instead of stealing it. The terminal search overlay mounts
    /// inside the pane's scroll view but not inside its surface view, so it
    /// correctly reads as foreign here.
    private static func responderYieldsToPaneFocus(_ responder: NSResponder?) -> Bool {
        guard let responder else { return true }
        if responder is NSWindow { return true }
        return cmuxOwningGhosttyView(for: responder) != nil
    }
}

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

    /// The window's current pane layout — drives the SwiftUI split container.
    private(set) var layout: RemoteTmuxLayoutNode
    /// Bumped by ``reconcile(layout:)`` only when the layout's STRUCTURE changes
    /// (pane set or split nesting — see ``structureSignature(of:)``), never on a
    /// geometry-only reflow. Client sizing re-arms off this, not off ``layout``:
    /// a geometry-only `%layout-change` is tmux's echo of our own
    /// `refresh-client -C` (or a co-attached client's resize-pane), and the
    /// summed grid that would be re-pushed is itself downstream of that reflow
    /// (the split container divides pixels by tmux's cell weights). At pixel
    /// widths where cmux's pixel division and tmux's integer cell division
    /// disagree by a column, re-pushing on the echo has no fixed point — the
    /// client size alternates ±1 column indefinitely, SIGWINCH-storming every
    /// pane in the session. Structural changes must still re-push: each
    /// split/close adds or removes a separator column/row in the summed grid.
    private(set) var layoutStructureVersion = 0
    /// Bumped on a geometry-only reconcile while ``geometryCorrectionBudget``
    /// remains, re-arming ONE bounded sizing pass. Geometry-only layout changes
    /// are usually the echo of our own `refresh-client -C` — never re-arm
    /// unboundedly on those (that loop has no fixed point at some pixel widths)
    /// — but they are also how genuinely FOREIGN changes arrive: a co-attached
    /// client's `resize-pane`, or another writer (a single-pane tab) moving the
    /// shared client size. Those must re-push or the window sticks mismatched
    /// (panes rendering one column short of their PTY, wrapping every full-width
    /// line). The budget resolves the ambiguity without distinguishing the two:
    /// each geometry re-arm spends 1 of 2; the budget refills only on a
    /// structural change or a local trigger (mount, outer resize, tab shown).
    /// A foreign change heals in one pass (its echo then dedups to silence); an
    /// echo storm burns the budget and goes quiet instead of oscillating.
    private(set) var sizingCorrectionVersion = 0
    @ObservationIgnored private var geometryCorrectionBudget = 2
    /// The tmux pane the user last focused (drives the focus overlay + splits).
    private(set) var activePaneId: Int?

    /// Refills the geometry-correction budget. Called by the view on every
    /// LOCAL sizing trigger (mount, outer-area change, tab becoming visible) —
    /// the signals that cannot be a tmux echo.
    func noteLocalSizingTrigger() { geometryCorrectionBudget = 2 }

    /// ``TerminalPanel`` per tmux pane id. Not observation-tracked: the view
    /// re-reads it whenever ``layout`` (which IS tracked) changes, and the two
    /// are always updated together in ``reconcile(layout:)``.
    @ObservationIgnored private var panelsByPaneId: [Int: TerminalPanel] = [:]
    /// Stable synthetic bonsplit pane id per tmux pane (for portal hosting),
    /// minted at panel-creation time so the view body is a pure read.
    @ObservationIgnored private var syntheticPaneIds: [Int: PaneID] = [:]

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

    /// Updates the layout, creating panels for new panes and tearing down panels
    /// for panes tmux removed (surviving panes keep their panel and scrollback).
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
        // Structural change (split/close/re-nest) vs geometry-only reflow: the
        // former always re-arms client sizing (the separator arithmetic changed)
        // and refills the correction budget; the latter re-arms at most
        // ``geometryCorrectionBudget`` bounded passes (see
        // ``sizingCorrectionVersion``). `init` reconciles the layout it just
        // stored, so the first pass never bumps — the view's onAppear owns the
        // initial push.
        if Self.structureSignature(of: newLayout) != Self.structureSignature(of: layout) {
            geometryCorrectionBudget = 2
            layoutStructureVersion += 1
        } else if layout != newLayout, geometryCorrectionBudget > 0 {
            geometryCorrectionBudget -= 1
            sizingCorrectionVersion += 1
        }
        if layout != newLayout { layout = newLayout }
    }

    /// Routes a tmux `%output` to the surface for `paneId` (no-op if unknown).
    func routeOutput(paneId: Int, data: Data) {
        panelsByPaneId[paneId]?.surface.processRemoteOutput(data)
    }

    /// Tells tmux to size this session's windows to the rendered cmux area, so
    /// captured/live pane content matches the on-screen grid.
    ///
    /// The summed grid IS downstream of tmux's layout (the split container divides
    /// pixels proportionally to tmux's cell weights, and the leaf grids quantize
    /// that), so calling this from a tmux-originated layout echo closes a feedback
    /// loop that has no fixed point at some pixel widths (±1-column oscillation,
    /// forever). Loop safety is therefore the CALLER's job: push on local triggers
    /// (appear, outer-area change, tab shown), on ``layoutStructureVersion``
    /// changes, and on at most the budgeted ``sizingCorrectionVersion`` passes.
    ///
    /// Dedup is against the CONNECTION's last-requested size — shared session
    /// state — never a mirror-local cache: the client size has other writers
    /// (single-pane tabs, reconnect re-apply), and after one of them moves it, a
    /// private cache would swallow the very re-push that reconciles this window.
    /// Returns `true` once every pane surface is live and the size was applied
    /// (sent, or already current); `false` while any surface has no live grid
    /// yet, so the caller should retry. Idempotent.
    @discardableResult
    func updateClientSize() -> Bool {
        // Size tmux from the ACTUAL rendered leaf grids, summed through the layout
        // tree with tmux's 1-cell pane separators — NOT from the outer content area
        // divided by cell size. The outer/cell math counts the local SwiftUI split
        // dividers as columns, so tmux ends up ~1 col wider than the ghostty surfaces
        // actually render; that width disagreement wraps zsh's PROMPT_SP "%" filler and
        // misplaces the cursor in split panes. Reporting the real summed grid makes
        // tmux's per-pane width equal each surface's rendered width, so live %output
        // paints faithfully. Returns false (caller retries) until every leaf is live.
        guard let connection else { return true }
        guard let grid = renderedLayoutGridCells(of: layout) else { return false }
        let cols = max(20, grid.cols)
        let rows = max(5, grid.rows)
        if let last = connection.lastRequestedClientSize, last.columns == cols, last.rows == rows {
            // The TOTAL is right — now make tmux's per-pane deal match. tmux
            // redistributes a new window size with its own remainder rule, so
            // it can hand the odd column to a different pane than the one whose
            // pixels grew: every total can be dealt wrong pane-wise, and at
            // some geometries no total deals right. Pin only the mismatched
            // panes to their rendered dims (the sum is consistent by
            // construction, so tmux can honor every pin). Ordering falls out of
            // the settle-confirm rounds: one round pushes the total, the next
            // finds the total deduped and pins the deal, the next verifies.
            let pins = Self.panePins(of: layout, leafGrid: leafGridProvider(of: layout))
            #if DEBUG
            lastPanePinsForTesting = pins
            #endif
            for pin in pins {
                var cmd = "resize-pane -t @\(windowId).%\(pin.paneId)"
                if let c = pin.cols { cmd += " -x \(c)" }
                if let r = pin.rows { cmd += " -y \(r)" }
                connection.send(cmd)
            }
            return true
        }
        connection.setClientSize(columns: cols, rows: rows)
        return true
    }

    /// A pane whose tmux-dealt dims differ from its rendered grid, and the
    /// dimension(s) to pin (`nil` = already matches).
    struct PanePin: Equatable {
        let paneId: Int
        let cols: Int?
        let rows: Int?
    }

    /// The panes tmux dealt differently than their surfaces render. Pure over
    /// `(node, leafGrid)` — `nonisolated` and unit-testable. Leaves with no
    /// grid are skipped (nothing trustworthy to pin to).
    nonisolated static func panePins(
        of node: RemoteTmuxLayoutNode,
        leafGrid: (Int) -> (cols: Int, rows: Int)?
    ) -> [PanePin] {
        var pins: [PanePin] = []
        func walk(_ n: RemoteTmuxLayoutNode) {
            switch n.content {
            case let .pane(id):
                guard let grid = leafGrid(id) else { return }
                let c = grid.cols != n.width ? grid.cols : nil
                let r = grid.rows != n.height ? grid.rows : nil
                if c != nil || r != nil { pins.append(PanePin(paneId: id, cols: c, rows: r)) }
            case let .horizontal(children), let .vertical(children):
                children.forEach(walk)
            }
        }
        walk(node)
        return pins
    }

    /// The window grid size implied by the ACTUAL rendered leaf-pane grids, folded
    /// through the layout tree via ``summedGridCells(of:leafGrid:)``. Returns `nil`
    /// if any leaf surface has no live rendered grid yet, so the caller retries once
    /// it does.
    /// The per-leaf grid source shared by the fold and the pane pins: the live
    /// surface grid, with a sliver fallback to tmux's own dims — a pane squeezed
    /// to a few cells (a co-attached client can resize one down to a single
    /// cell) may never report a live grid, and one degenerate pane must not
    /// become a total sizing outage for the window.
    private func leafGridProvider(of node: RemoteTmuxLayoutNode) -> (Int) -> (cols: Int, rows: Int)? {
        var tmuxDims: [Int: (cols: Int, rows: Int)] = [:]
        func collect(_ n: RemoteTmuxLayoutNode) {
            switch n.content {
            case let .pane(id): tmuxDims[id] = (n.width, n.height)
            case let .horizontal(children), let .vertical(children): children.forEach(collect)
            }
        }
        collect(node)
        let surfaceGrid: (Int) -> (cols: Int, rows: Int)?
        #if DEBUG
        surfaceGrid = leafGridOverrideForTesting ?? { [panelsByPaneId] paneId in
            panelsByPaneId[paneId]?.surface.renderedGridCells()
                .map { (cols: $0.columns, rows: $0.rows) }
        }
        #else
        surfaceGrid = { [panelsByPaneId] paneId in
            panelsByPaneId[paneId]?.surface.renderedGridCells()
                .map { (cols: $0.columns, rows: $0.rows) }
        }
        #endif
        return { paneId in
            if let grid = surfaceGrid(paneId) { return grid }
            if let dims = tmuxDims[paneId], dims.cols <= 3 || dims.rows <= 3 { return dims }
            return nil
        }
    }

    private func renderedLayoutGridCells(of node: RemoteTmuxLayoutNode) -> (cols: Int, rows: Int)? {
        Self.summedGridCells(of: node, leafGrid: leafGridProvider(of: node))
    }

    /// Folds per-leaf grid sizes through the tmux split tree exactly as tmux lays a
    /// window out: a horizontal split's width is the sum of its children's widths plus
    /// one separator column between each (height = max child height); a vertical split
    /// is the transpose (max width, summed heights + one separator row between each).
    /// The `+ (count - 1)` separator term is what makes the window size we report equal
    /// the leaves' rendered widths PLUS tmux's own divider columns, so tmux then splits
    /// that window back into per-pane widths that match each surface — the invariant that
    /// keeps zsh's PROMPT_SP "%" filler from wrapping. Returns `nil` if `leafGrid`
    /// returns `nil` for any pane (its surface has no live grid yet), so the caller can
    /// retry. Pure over `(node, leafGrid)` — no live-surface access — so it's
    /// `nonisolated` and unit testable with stubbed leaf sizes.
    nonisolated static func summedGridCells(
        of node: RemoteTmuxLayoutNode,
        leafGrid: (Int) -> (cols: Int, rows: Int)?
    ) -> (cols: Int, rows: Int)? {
        switch node.content {
        case let .pane(paneId):
            return leafGrid(paneId)
        case let .horizontal(children):
            var totalCols = 0
            var maxRows = 0
            for child in children {
                guard let g = summedGridCells(of: child, leafGrid: leafGrid) else { return nil }
                totalCols += g.cols
                maxRows = max(maxRows, g.rows)
            }
            return (totalCols + max(0, children.count - 1), maxRows)
        case let .vertical(children):
            var maxCols = 0
            var totalRows = 0
            for child in children {
                guard let g = summedGridCells(of: child, leafGrid: leafGrid) else { return nil }
                maxCols = max(maxCols, g.cols)
                totalRows += g.rows
            }
            return (maxCols, totalRows + max(0, children.count - 1))
        }
    }

    /// The split-tree SHAPE (node kinds + pane ids, geometry stripped). Two layouts
    /// with the same signature differ only in cell extents — the fingerprint of a
    /// tmux-side reflow: the echo of our own `refresh-client -C`, or a co-attached
    /// client's `resize-pane`. Those must not re-arm client sizing (see
    /// ``layoutStructureVersion``). A split, close, or re-nest changes the
    /// signature, and those MUST re-push: each split adds a separator column/row
    /// to the summed grid. Pure over the node — `nonisolated` and unit-testable.
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

    #if DEBUG
    /// Stubs the per-pane rendered grids so sizing behavior is testable without
    /// live surfaces: ``updateClientSize()``'s liveness/floor/dedup contract and
    /// — critically — that ``reconcile(layout:)`` never pushes a size by itself
    /// (pushing from the reconcile path would re-open the geometry-echo loop
    /// that ``layoutStructureVersion`` exists to prevent).
    @ObservationIgnored var leafGridOverrideForTesting: ((Int) -> (cols: Int, rows: Int)?)?
    /// The shared (connection-level) last-requested size — what dedup compares
    /// against and what a send updates. Tests read this to observe both halves.
    var lastClientSizeForTesting: (cols: Int, rows: Int)? {
        connection?.lastRequestedClientSize.map { (cols: $0.columns, rows: $0.rows) }
    }
    /// The pane pins computed by the most recent dedup-hit sizing pass.
    @ObservationIgnored var lastPanePinsForTesting: [PanePin] = []
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

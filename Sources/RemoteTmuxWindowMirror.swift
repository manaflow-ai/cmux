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
    /// The tmux pane the user last focused (drives the focus overlay + splits).
    private(set) var activePaneId: Int?

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
        if layout != newLayout { layout = newLayout }
    }

    /// Routes a tmux `%output` to the surface for `paneId` (no-op if unknown).
    func routeOutput(paneId: Int, data: Data) {
        panelsByPaneId[paneId]?.surface.processRemoteOutput(data)
    }

    @ObservationIgnored private var lastClientSize: (cols: Int, rows: Int)?

    /// Tells tmux to size this session's windows to the rendered cmux area, so
    /// captured/live pane content matches the on-screen grid. Sends
    /// `refresh-client -C` only when the grid actually changes (no feedback loop:
    /// the summed grid is derived from the surfaces, not from what tmux reflows to).
    /// Returns `true` once every pane surface is live and the size was applied (sent,
    /// or already current via the `lastClientSize` dedup); `false` while any surface
    /// has no live grid yet, so the caller should retry. Idempotent.
    ///
    /// `contentSizePoints` (the outer pixel area) is intentionally unused: sizing is
    /// now derived from the rendered leaf grids, not the outer area. The parameter is
    /// kept so the caller's resize-triggered call site is unchanged.
    @discardableResult
    func updateClientSize(contentSizePoints: CGSize) -> Bool {
        // Size tmux from the ACTUAL rendered leaf grids, summed through the layout
        // tree with tmux's 1-cell pane separators — NOT from the outer content area
        // divided by cell size. The outer/cell math counts the local SwiftUI split
        // dividers as columns, so tmux ends up ~1 col wider than the ghostty surfaces
        // actually render; that width disagreement wraps zsh's PROMPT_SP "%" filler and
        // misplaces the cursor in split panes. Reporting the real summed grid makes
        // tmux's per-pane width equal each surface's rendered width, so live %output
        // paints faithfully. Returns false (caller retries) until every leaf is live.
        _ = contentSizePoints
        guard let grid = renderedLayoutGridCells(of: layout) else { return false }
        let cols = max(20, grid.cols)
        let rows = max(5, grid.rows)
        guard lastClientSize?.cols != cols || lastClientSize?.rows != rows else { return true }
        lastClientSize = (cols, rows)
        connection?.setClientSize(columns: cols, rows: rows)
        return true
    }

    /// The window grid size implied by the ACTUAL rendered leaf-pane grids, folded
    /// through the layout tree via ``summedGridCells(of:leafGrid:)``. Returns `nil`
    /// if any leaf surface has no live rendered grid yet, so the caller retries once
    /// it does.
    private func renderedLayoutGridCells(of node: RemoteTmuxLayoutNode) -> (cols: Int, rows: Int)? {
        Self.summedGridCells(of: node) { paneId in
            panelsByPaneId[paneId]?.surface.renderedGridCells()
                .map { (cols: $0.columns, rows: $0.rows) }
        }
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
    /// retry. Pure over `(node, leafGrid)` — no live-surface access — so it's unit
    /// testable with stubbed leaf sizes.
    static func summedGridCells(
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

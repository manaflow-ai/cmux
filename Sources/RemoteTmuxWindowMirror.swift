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

    /// Composes the tmux client grid from the per-pane rendered grids by walking
    /// the layout tree and summing grid dimensions along each split axis (+1 per
    /// tmux divider between children), taking the max on the cross axis.
    ///
    /// This is a pure function with no side effects, testable without a live
    /// Ghostty surface or window.
    ///
    /// - Parameters:
    ///   - node: The layout subtree to compose.
    ///   - gridForPane: Returns the rendered `(cols, rows)` for a leaf pane id,
    ///     or `nil` if the surface is not yet live.
    /// - Returns: The composed client grid, or `nil` when any leaf surface is not
    ///   yet live (caller should retry).
    nonisolated static func composeClientGrid(
        _ node: RemoteTmuxLayoutNode,
        gridForPane: (Int) -> (cols: Int, rows: Int)?
    ) -> (cols: Int, rows: Int)? {
        switch node.content {
        case let .pane(id):
            return gridForPane(id)
        case let .horizontal(children):
            let grids = children.compactMap { composeClientGrid($0, gridForPane: gridForPane) }
            guard grids.count == children.count, !grids.isEmpty else { return nil }
            // Sum cols along the split axis (+1 per tmux divider between children),
            // take max rows on the cross axis.
            return (grids.reduce(0) { $0 + $1.cols } + (grids.count - 1), grids.map(\.rows).max() ?? 0)
        case let .vertical(children):
            let grids = children.compactMap { composeClientGrid($0, gridForPane: gridForPane) }
            guard grids.count == children.count, !grids.isEmpty else { return nil }
            // Sum rows along the split axis (+1 per tmux divider), take max cols.
            return (grids.map(\.cols).max() ?? 0, grids.reduce(0) { $0 + $1.rows } + (grids.count - 1))
        }
    }

    /// Tells tmux to size this session's windows to the rendered cmux area, so
    /// captured/live pane content matches the on-screen grid. Derives cols/rows
    /// from each pane's actual rendered grid via ``composeClientGrid(_:gridForPane:)``
    /// — this correctly excludes pane chrome (the 24+1pt ``RemoteTmuxPaneHeader``)
    /// that the pixel-divide approach over-counted, which was the root cause of the
    /// top-clip on in-tab splits (issue #7053).
    ///
    /// `contentSizePoints` is the container size that triggered the call (via
    /// `onChange(of: geo.size)`) and is no longer used in the grid calculation;
    /// the parameter is kept so the call site stays unchanged.
    ///
    /// Returns `true` once all pane surfaces are live and the size was applied (sent,
    /// or already current via the `lastClientSize` dedup); `false` when any pane has
    /// not yet reported its rendered grid, so the caller should retry. Idempotent.
    @discardableResult
    func updateClientSize(contentSizePoints: CGSize) -> Bool {
        guard let grid = Self.composeClientGrid(layout, gridForPane: { paneId in
            panelsByPaneId[paneId]?.surface.renderedGridCells().map { ($0.columns, $0.rows) }
        }) else { return false }
        let cols = max(20, grid.cols)
        let rows = max(5, grid.rows)
        guard lastClientSize?.cols != cols || lastClientSize?.rows != rows else { return true }
        lastClientSize = (cols, rows)
        connection?.setClientSize(columns: cols, rows: rows)
        return true
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

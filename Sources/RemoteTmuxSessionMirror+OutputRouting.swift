import CmuxTerminal
import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxSessionMirror {
    func routeOutput(paneId: Int, data: Data) {
        // Strip the screen/tmux `ESC k <title> ST` window-title escape that a remote
        // shell (TERM=screen*/tmux*) emits. Per-pane state survives chunk splits.
        var filter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        let cleaned = filter.filter(data)
        titleFilters[paneId] = filter
        routeCleanedOutput(paneId: paneId, data: cleaned)
    }

    /// Applies an authoritative snapshot independently from the logical live
    /// escape stream, then catches that stream up across the capture boundary.
    func routeSeed(paneId: Int, seed: RemoteTmuxPaneSeed) {
        var liveFilter = titleFilters[paneId] ?? RemoteTmuxScreenTitleFilter()
        for data in seed.discardedOutput { _ = liveFilter.filter(data) }

        var snapshotFilter = RemoteTmuxScreenTitleFilter()
        routeCleanedOutput(paneId: paneId, data: snapshotFilter.filter(seed.snapshot))
        for data in seed.catchUpOutput {
            routeCleanedOutput(paneId: paneId, data: liveFilter.filter(data))
        }
        titleFilters[paneId] = liveFilter
        routeCleanedOutput(paneId: paneId, data: seed.state)
    }

    private func routeCleanedOutput(paneId: Int, data: Data) {
        guard !data.isEmpty else { return }

        // Multi-pane window: its in-tab renderer owns the pane's surface.
        if let windowId = windowIdContaining(pane: paneId),
           let mirror = windowMirrorByWindowId[windowId] {
            mirror.routeOutput(paneId: paneId, data: data)
            return
        }
        // Single-pane window: route to the window-tab's panel surface.
        guard let workspace,
              let panelId = panelIdByPane[paneId],
              let panel = workspace.panels[panelId] as? TerminalPanel else { return }
        panel.surface.processRemoteOutput(data)
    }
}

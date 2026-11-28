import Foundation

@MainActor
extension RemoteTmuxSessionMirror {
    /// The find bar's full-history load for one of this mirror's panes, made on first use
    /// and kept until tmux stops reporting the pane.
    func fullHistorySearch(forPane paneId: Int) -> RemoteTmuxFullHistorySearch {
        if let search = fullHistorySearchByPane[paneId] { return search }
        let search = RemoteTmuxFullHistorySearch(
            reseed: { [weak self] in
                await self?.connection.reseedPaneWithFullHistory(paneId: paneId) ?? .failed
            },
            rerunSearch: {}
        )
        fullHistorySearchByPane[paneId] = search
        return search
    }
}

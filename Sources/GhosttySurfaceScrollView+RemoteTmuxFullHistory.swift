import CmuxTerminal
import Foundation

extension GhosttySurfaceScrollView {
    /// The find bar's full-history action, for a mirrored tmux pane only. The load belongs
    /// to the pane, so a rebuilt find bar shows the same one; this find session supplies
    /// the search it reruns.
    @MainActor
    func makeRemoteTmuxFullHistorySearch(
        terminalSurface: TerminalSurface,
        searchState: TerminalSurface.SearchState
    ) -> RemoteTmuxFullHistorySearch? {
        guard let search = AppDelegate.shared?.remoteTmuxController.fullHistorySearch(
            forSurfaceId: terminalSurface.id
        ) else { return nil }
        search.rerunSearch = { [weak terminalSurface, weak searchState] in
            guard let needle = searchState?.needle, !needle.isEmpty else { return }
            _ = terminalSurface?.performInternalBindingAction("search:\(needle)")
        }
        return search
    }
}

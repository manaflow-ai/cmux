import CmuxTerminal
import Foundation

extension GhosttySurfaceScrollView {
    /// The find bar's full-history action, for a mirrored tmux pane only. One per
    /// find session: a later attach or reconnect seed replaces the loaded history.
    @MainActor
    func makeRemoteTmuxFullHistorySearch(
        terminalSurface: TerminalSurface,
        searchState: TerminalSurface.SearchState
    ) -> RemoteTmuxFullHistorySearch? {
        let surfaceId = terminalSurface.id
        guard AppDelegate.shared?.remoteTmuxController.isMirrorPaneSurface(surfaceId) == true else {
            return nil
        }
        return RemoteTmuxFullHistorySearch(
            reseed: {
                await AppDelegate.shared?.remoteTmuxController.reseedFullHistory(forSurfaceId: surfaceId)
                    ?? .failed
            },
            rerunSearch: { [weak terminalSurface, weak searchState] in
                guard let needle = searchState?.needle, !needle.isEmpty else { return }
                _ = terminalSurface?.performInternalBindingAction("search:\(needle)")
            }
        )
    }
}

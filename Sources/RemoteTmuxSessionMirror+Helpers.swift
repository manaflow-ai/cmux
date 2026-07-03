import Foundation
import CmuxRemoteSession
import CmuxRemoteWorkspace

extension RemoteTmuxSessionMirror {
    nonisolated static func shouldSeedSinglePaneDisplay(for window: RemoteTmuxWindow) -> Bool {
        window.paneIDsInOrder.count == 1
    }

    /// Computes the target tab order for a remote-tmux-driven reorder, or `nil`
    /// when no reorder is needed or safe. Pure helper called by
    /// `Workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder:)`.
    ///
    /// - Parameters:
    ///   - current: the workspace's current mirror-tab order (panel ids).
    ///   - requested: the tmux window order mapped to panel ids.
    /// - Returns: the new order to apply, or `nil` when the tabs already match
    ///   `requested` or when `requested` (restricted to currently-present tabs) is
    ///   not a permutation of `current` (sets diverge; leave the tabs untouched).
    nonisolated static func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? {
        let present = Set(current)
        let desired = requested.filter { present.contains($0) }
        guard desired.count == current.count, Set(desired) == present else { return nil }
        return desired == current ? nil : desired
    }
}

import Foundation
import CmuxRemoteSession
import CmuxRemoteWorkspace

extension RemoteTmuxSessionMirror {
    nonisolated static func shouldSeedSinglePaneDisplay(for window: RemoteTmuxWindow) -> Bool {
        window.paneIDsInOrder.count == 1
    }

    /// The tab title for a mirrored window: the tmux window name, or a localized
    /// placeholder when tmux hasn't reported one. tmux window names are
    /// content-derived (like every other cmux tab title) so the name itself is
    /// not translated; only the empty-name placeholder is localized.
    nonisolated static func tabTitle(for window: RemoteTmuxWindow) -> String {
        let trimmed = window.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            ? String(localized: "remoteTmux.tab.window", defaultValue: "tmux window")
            : trimmed
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

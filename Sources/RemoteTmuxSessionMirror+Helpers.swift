import Foundation
import CmuxRemoteSession

extension RemoteTmuxSessionMirror {
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

    /// The workspace's panels that no tmux window owns, such as the terminal cmux opens when
    /// the workspace's last tab closes. A reorder leaves their tabs where they are.
    var panelsWithoutWindow: Set<UUID> {
        guard let workspace else { return [] }
        return Set(workspace.panels.keys).subtracting(windowIdByPanel.keys)
    }

    /// Computes the target tab order for a remote-tmux-driven reorder, or `nil`
    /// when no reorder is needed or safe. Pure helper called by
    /// `Workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder:keepingInPlace:)`.
    ///
    /// - Parameters:
    ///   - current: the workspace's current tab order (panel ids).
    ///   - requested: the tmux window order mapped to panel ids.
    ///   - fixed: tabs no tmux window owns. They keep their positions and the
    ///     rest are reordered around them.
    /// - Returns: the new order to apply, or `nil` when the tabs already match
    ///   `requested` or when `requested` (restricted to currently-present tabs) is
    ///   not a permutation of the tabs outside `fixed` (sets diverge; leave the
    ///   tabs untouched).
    nonisolated static func mirrorTabReorder(
        current: [UUID],
        requested: [UUID],
        keepingInPlace fixed: Set<UUID> = []
    ) -> [UUID]? {
        let movable = current.filter { !fixed.contains($0) }
        let present = Set(movable)
        let desired = requested.filter { present.contains($0) }
        guard desired.count == movable.count, Set(desired) == present else { return nil }
        var next = desired.makeIterator()
        let reordered = current.map { fixed.contains($0) ? $0 : (next.next() ?? $0) }
        return reordered == current ? nil : reordered
    }
}

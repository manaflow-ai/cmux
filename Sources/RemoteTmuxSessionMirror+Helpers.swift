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

    /// Computes the target tab order for a remote-tmux-driven reorder, or `nil`
    /// when no reorder is needed. Pure helper called by
    /// `Workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder:)`.
    ///
    /// Ids in `requested` mean "place these, in this relative order". Ids in
    /// `current` but absent from `requested` — a sibling browser tab, or a tmux
    /// window whose tab the reconcile pass hasn't created yet — are anchored at
    /// their current index rather than failing the reorder. That is the subset
    /// rule `RemoteTmuxControlMessageDecoding.windowOrder(_:applyingReorder:)`
    /// applies in the reverse direction, so a local drag and a remote reorder
    /// converge instead of fighting.
    ///
    /// - Parameters:
    ///   - current: the FULL current tab-strip order (panel ids), tmux window
    ///     tabs and any non-tmux tabs interleaved.
    ///   - requested: the desired relative order for a subset of `current`.
    /// - Returns: the FULL new strip order — the caller applies it as absolute
    ///   tab-strip indices — or `nil` when nothing would change or `requested`
    ///   contains a duplicate id.
    nonisolated static func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? {
        let present = Set(current)
        // A requested id with no tab yet can't be placed; rebuild creates it and re-runs.
        let desired = requested.filter { present.contains($0) }
        let desiredSet = Set(desired)
        guard desiredSet.count == desired.count else { return nil }
        guard !desired.isEmpty else { return nil }

        var iterator = desired.makeIterator()
        let newOrder = current.map { desiredSet.contains($0) ? (iterator.next() ?? $0) : $0 }
        return newOrder == current ? nil : newOrder
    }
}

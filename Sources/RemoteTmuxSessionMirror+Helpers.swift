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
    /// `current` is the FULL current tab-strip order — tmux window tabs and any
    /// non-tmux tab (a sibling browser tab) interleaved. `requested` is not
    /// necessarily tmux-only either: two of the three call sites
    /// (`Workspace.normalizePinnedTabs`, and the optimistic-reorder rollback in
    /// `Workspace+RemoteTmuxTabOrder.swift`) pass a full local order too, while
    /// only the reconcile path passes a tmux-only order. Either way, ids in
    /// `requested` are "please place these, in this relative order"; ids in
    /// `current` but absent from `requested` (a non-tmux tab, or a tmux window
    /// whose tab the reconcile pass hasn't created yet) are anchored in place —
    /// this is the same subset rule
    /// `RemoteTmuxControlMessageDecoding.windowOrder(_:applyingReorder:)` applies
    /// for the reverse direction, so a local drag and a remote reorder converge
    /// instead of fighting.
    ///
    /// Always returns the FULL new strip order (never just the reordered
    /// subset) — `Workspace.reorderRemoteTmuxMirrorTabs` applies the result as
    /// absolute tab-strip indices.
    ///
    /// - Parameters:
    ///   - current: the workspace's current full mirror-tab order (panel ids).
    ///   - requested: the desired relative order for a subset of `current`.
    /// - Returns: the new full order to apply, or `nil` when nothing would
    ///   change or `requested` contains a duplicate id.
    nonisolated static func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? {
        let present = Set(current)
        // Ids with no tab yet (e.g. a tmux window the reconcile pass hasn't
        // created a tab for) can't be placed here; the rebuild creates them
        // and re-runs.
        let desired = requested.filter { present.contains($0) }
        let desiredSet = Set(desired)
        guard desiredSet.count == desired.count else { return nil } // duplicate id: refuse
        guard !desired.isEmpty else { return nil }

        var iterator = desired.makeIterator()
        let newOrder = current.map { desiredSet.contains($0) ? (iterator.next() ?? $0) : $0 }
        return newOrder == current ? nil : newOrder
    }
}

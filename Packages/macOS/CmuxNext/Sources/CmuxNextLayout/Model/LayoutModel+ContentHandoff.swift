public import Foundation

extension LayoutModel {
    /// The next structural change moves what `pane` shows into the pane it adds: a lone agent chat
    /// docking left while a link opens beside it, the link's tab left behind in `pane`. That change
    /// does not play as a split: the added pane shows at its place from its first frame (the
    /// content stays where the person was looking), and `pane`, which shows the new tab now,
    /// slides in at its final size from the screen edge across from it. One-shot; it lapses after
    /// a few seconds when no such change comes.
    public func handOffContent(of pane: PaneID) {
        contentHandoff = (pane, ProcessInfo.processInfo.systemUptime + Self.contentHandoffWindow)
    }

    /// ``handOffContent(of:)`` for the change `move` makes, which reports through `done` whether it
    /// happened: the hint is set before `move` runs and dropped when the change fails (a folder
    /// opened from a lone chat docks it through `ChatColumnPlacement.route`).
    public func handOffContent(of pane: PaneID, during move: @MainActor (_ done: @escaping @MainActor (Bool) -> Void) -> Void) {
        handOffContent(of: pane)
        move { [weak self] moved in
            if !moved, self?.contentHandoff?.pane == pane { self?.cancelContentHandoff() }
        }
    }

    /// Drops a hint whose change never came (the move failed), so a later split plays as a split.
    public func cancelContentHandoff() {
        contentHandoff = nil
    }

    /// The pane a pending hand-off names, if it has not lapsed. The change that plays it clears it
    /// (`ScreenContentView.reconcile`).
    var pendingContentHandoff: PaneID? {
        guard let handoff = contentHandoff, ProcessInfo.processInfo.systemUptime < handoff.until else { return nil }
        return handoff.pane
    }
}

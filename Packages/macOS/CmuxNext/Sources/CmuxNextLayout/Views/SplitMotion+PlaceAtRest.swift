import AppKit

/// A render-server spring's start (chrome-parity R2): what moves goes to rest once, and
/// the overlay plane places the pane chrome there before any spring starts.
extension SplitMotion {
    /// A render-server spring's start: every host of `panes` (with `laysOut`, when its rest has room) goes to
    /// its rest frame and `placeDividers` puts the change's dividers at theirs
    /// (`ScreenDividers.place`), then the overlay plane places their rings and
    /// dims there in one sync (the change's apply sync), so each host's springs carry its chrome from
    /// that rest in one group (`PaneHostView.springToRest`) and nothing syncs the overlay again until
    /// they land. Returns the placed hosts with their moves.
    @MainActor
    static func placeAtRest(_ panes: [PaneID: RenderMove], laysOut: Bool, context: LayoutViewContext,
                            placeDividers: () -> Void) -> [(PaneID, PaneHostView, RenderMove)] {
        let placed: [(PaneID, PaneHostView, RenderMove)] = panes.compactMap { entry in
            context.hosts[entry.key].map { (entry.key, $0, entry.value) }
        }
        for (_, host, move) in placed {
            host.placeAtRest(move, laysOut: laysOut && move.to.width >= 1 && move.to.height >= 1)
        }
        placeDividers()
        context.overlaySyncNow()
        return placed
    }
}

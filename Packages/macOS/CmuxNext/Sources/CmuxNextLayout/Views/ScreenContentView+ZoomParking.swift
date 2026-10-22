import AppKit

/// The panes a zoom hides (`LayoutScreen.zoomHiddenPanes`) stay open: their hosts park here, hidden
/// under the zoomed pane with their content alive, and the unzoom shows the same views again
/// (panes-perf 2026-10-22: a zoom released 29 pane controllers at 30 panes and the unzoom made
/// all 29 again). A parked pane renders nothing (the layout reports it hidden, `PanePresence`).
extension ScreenContentView {
    /// Hides `pane`'s host when the zoom hides it. Returns false for a pane the zoom does not hide.
    func park(_ pane: PaneID) -> Bool {
        guard zoomHidden.contains(pane), let host = context.hosts[pane], host.superview === self else { return false }
        if !host.isHidden { host.isHidden = true }
        return true
    }

    /// Lets go of parked hosts the zoom no longer hides (their pane closed while zoomed, or moved to
    /// another screen); every parked host with `all` (the screen goes away).
    func releaseParked(all: Bool = false) {
        for case let host as PaneHostView in subviews where host.isHidden && paneFrames[host.pane] == nil {
            guard all || (!zoomHidden.contains(host.pane) && !covered.contains(host.pane)) else { continue }
            if context.livePanes.contains(host.pane) { host.removeFromSuperview() } else { context.release(host.pane) }
        }
    }
}

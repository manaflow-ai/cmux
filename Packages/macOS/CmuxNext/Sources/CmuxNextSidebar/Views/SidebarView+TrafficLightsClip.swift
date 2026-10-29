import AppKit
import CmuxNextDesign

// With the minimal titlebar the header row is the tab strip's height, so the
// scrolling bands start level with the panes' content, above the bottom of the
// traffic lights' row. At rest that is right; scrolled, rows slid up under the
// lights and stayed in view there. Each band's top mask hides, while content
// is hidden above it, everything down to the titlebar's bottom and fades in
// below it (claude-sr2, 2026-10-21). The bands do not move.
extension SidebarViewComponents {
    /// Sets each scrolling band's top clip: the part of it above
    /// `Metrics.titlebarHeight` (the sidebar's top is the window's), or none
    /// when the traffic lights are not over this sidebar.
    func clipBandsUnderTrafficLights() {
        for fade in [aboveFade, edgeFade] {
            fade.topClip = headerHasWindowControls ? max(0, Metrics.titlebarHeight - fade.frame.minY) : 0
        }
    }
}

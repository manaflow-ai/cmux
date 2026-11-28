public import CmuxNextDesign
public import CmuxNextPages
public import Foundation

/// The page's floating glass that the App draws under it (`pane.glass {surfaces}`; webviews
/// ui/glass/hostGlass.ts). Leo, 2026-11-06: "why the fuck is this not glass? Like the way the native
/// menus are. We can just do that, right? Like we're literally in Swift". A see-through Chromium page
/// cannot blur the window glass behind it, so a floating web glass read as a flat box; the page now
/// sends the boxes of the surfaces it marks, and the pane puts its own popover glass there, under the
/// page (AgentPaneView+HostGlass.swift). The page keeps every surface's content, layout and input.
/// Kept on the model: ``AgentPaneView`` is at its size limit.
@MainActor public final class AgentPaneHostGlass {
    /// What the page last sent; empty while it marks nothing (or an older page).
    public private(set) var surfaces: [AgentPaneHostGlassSurface] = []
    /// Called when ``surfaces`` changes: the view draws them before the reply goes back.
    var onChange: (() -> Void)?
    /// The glass views by surface id (AgentPaneView+HostGlass.swift).
    var views: [String: OverlaySurfaceView] = [:]
    /// The view that holds them, under the page.
    var container: AgentPaneHostGlassContainer?

    func update(_ next: [AgentPaneHostGlassSurface]) {
        guard next != surfaces else { return }
        surfaces = next
        onChange?()
    }

    /// The page loaded again or ended: its surfaces went with it.
    func pageLoaded() {
        update([])
    }
}

/// One marked surface (``PageHostGlassSurface``): the agent pane's `pane.glass` and every page's
/// `cmux.app.glass` (RFD 0207) decode one report the same way.
public typealias AgentPaneHostGlassSurface = PageHostGlassSurface

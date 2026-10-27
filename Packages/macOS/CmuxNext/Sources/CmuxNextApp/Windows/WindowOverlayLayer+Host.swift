import AppKit
import CmuxNextDesign
import CmuxNextLayout

/// The overlay layer's reads of its window's overlay host, and the agent cursor's forwards to it.
extension WindowOverlayLayer {
    /// Visible child windows that draw content above the parent: every child
    /// that is not one of the app's panels (in practice Chromium pages).
    static func contentChildWindows(of window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter { isContent($0) && $0.isVisible }
    }

    static func isContent(_ child: NSWindow) -> Bool { WindowOverlayHost.isPageWindow(child) }

    /// Reorders done (for `debug.layers`).
    var reorderCount: Int { WindowOverlayHost.existingHost(for: window)?.reorderCount ?? 0 }

    /// Whether the overlay is above every visible content child window (or
    /// not needed because there is none).
    var isOverlayAboveContent: Bool {
        guard !Self.contentChildWindows(of: window).isEmpty else { return true }
        return placement == .overlayWindow && WindowOverlayHost.existingHost(for: window)?.isAbovePages == true
    }

    /// The window's agent cursor layer (`WindowOverlayHost.agentCursorLayer`): y-down, content-view coordinates.
    var agentCursorLayer: CALayer { host.agentCursorLayer }
    /// The mask of the agent cursor's behind-window glass (`WindowOverlayHost.agentCursorGlassLayer`).
    var agentCursorGlassLayer: CALayer { host.agentCursorGlassLayer }
    /// The window's clickable agent cursor tags (`WindowOverlayHost.agentCursorTags`, held weakly).
    func setAgentCursorTags(_ tags: AgentCursorWindowTags) {
        if host.agentCursorTags !== tags { host.agentCursorTags = tags }
    }
    /// The window's agent cursors changed: the overlay takes the mouse over their tags.
    func agentCursorTagsDidChange() { host.agentCursorTagsDidChange() }

    var overlayPanel: NSWindow? { WindowOverlayHost.existingHost(for: window).flatMap { $0.isPanelAttached ? $0.panel : nil } }
    var adoptedPlanes: [OverlayPlane] { planes }
}

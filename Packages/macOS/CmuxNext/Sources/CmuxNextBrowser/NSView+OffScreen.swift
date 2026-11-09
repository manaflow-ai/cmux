public import AppKit

extension NSView {
    /// Whether no window draws this view: it has no window, it or an
    /// ancestor is hidden, or its window does not draw.
    ///
    /// An agent moves such a WebKit tab into a render window before it drives
    /// it (`AgentRenderWindows`).
    /// - Parameter windowDraws: Whether a window draws its content; the
    ///   default is ``AppKit/NSWindow/drawsContent``. Tests pass a fixed answer.
    /// - Returns: True when a person cannot see this view now.
    public func isOffScreen(windowDraws: @MainActor (NSWindow) -> Bool = { $0.drawsContent }) -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return true }
        return !windowDraws(window)
    }

    /// Whether an agent render window holds this view and should keep it, because the window of
    /// `home` (the pane that shows it) draws nothing.
    ///
    /// A pane's refresh (the tab's title changed after an agent navigated) must not pull a tab an
    /// agent drives back into a minimized or covered window in the middle of the agent's calls:
    /// there the page pauses, and the next pointer walk times out. The pane takes the tab back
    /// when its window draws again (`AgentRenderWindows.windowDidChangeOcclusion`).
    /// - Parameter home: The view that would show this one again.
    /// - Returns: True while the tab should stay off screen.
    public func staysParked(awayFrom home: NSView) -> Bool {
        window?.identifier == .agentRenderWindow && home.window.map { !$0.drawsContent } == true
    }
}

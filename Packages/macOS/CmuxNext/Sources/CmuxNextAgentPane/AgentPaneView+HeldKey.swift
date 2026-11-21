public import AppKit

extension AgentPaneView {
    /// Types the text of `event`, a key the New Tab key hold kept for this pane's ready field, into
    /// the page through its input bridge while cmux is not the active app.
    ///
    /// - Parameters:
    ///   - event: The held key.
    ///   - appIsActive: Whether cmux is the active app (injected for tests).
    /// - Returns: Whether the page took the key's text; false: the caller sends the key event on.
    @discardableResult
    public func typeHeldText(of event: NSEvent, appIsActive: Bool = NSApp.isActive) -> Bool {
        false
    }

    /// The agent pane in `window` whose Chromium page shows in `pageWindow` (a child window of
    /// `window`), found by the page window's center; nil when no pane's page covers it.
    ///
    /// - Parameters:
    ///   - pageWindow: A Chromium page window.
    ///   - window: The cmux window it is a child of.
    /// - Returns: The pane, or nil.
    public static func showing(chromiumPageWindow pageWindow: NSWindow, in window: NSWindow) -> AgentPaneView? {
        let center = CGPoint(x: pageWindow.frame.midX, y: pageWindow.frame.midY)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let pane = view as? AgentPaneView, let content = pane.chromiumPage?.contentView, let host = content.window,
               host.convertToScreen(content.convert(content.bounds, to: nil)).contains(center) { return pane }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

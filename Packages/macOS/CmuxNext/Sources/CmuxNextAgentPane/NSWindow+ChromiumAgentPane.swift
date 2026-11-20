public import AppKit

public extension NSWindow {
    /// The agent pane in this window whose Chromium page shows in `page`, a child window of this one.
    ///
    /// A Chromium page takes its keys in its own window over the pane. A key held for a page, or the key window a held
    /// key goes to, names that window; this finds the pane that shows it.
    ///
    /// - Parameter page: A child window of this window, such as the key window.
    /// - Returns: The agent pane whose page view's screen rect holds `page`'s center, or nil when none does.
    func chromiumAgentPane(showingPageIn page: NSWindow) -> AgentPaneView? {
        let center = CGPoint(x: page.frame.midX, y: page.frame.midY)
        var stack: [NSView] = contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let pane = view as? AgentPaneView, let content = pane.chromiumPage?.contentView, let host = content.window,
               host.convertToScreen(content.convert(content.bounds, to: nil)).contains(center) { return pane }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

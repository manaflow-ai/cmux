public import AppKit

/// The bar over a New Tab page (cx-e2aa, Lawrence 2026-10-09: "we should show the omnibar in new
/// tab page"). The App gives the pane its omnibar row once (`view.topBar.set`); the pane shows it on
/// top while the page is a New Tab page (spare, adopted, recycled or restored alike) and gives the
/// page the whole pane once it becomes a chat. The bar never covers the page: the page is laid out
/// below it, and autoresizing keeps the bar on top, full width, as the pane resizes.
@MainActor public final class AgentPaneTopBar {
    private weak var pane: AgentPaneView?
    /// The bar the App put over the page, shown or not.
    public private(set) var view: NSView?
    private var height: CGFloat = 0

    init(pane: AgentPaneView) { self.pane = pane }

    /// Puts `bar` (nil: none) over the page, `height` points tall, while the page is a New Tab page.
    public func set(_ bar: NSView?, height: CGFloat) {
        guard let pane else { return }
        if view !== bar { view?.removeFromSuperview() }
        view = bar
        self.height = max(0, height)
        if let bar, bar.superview !== pane { pane.addSubview(bar) }
        pane.model.onNewTabChange = { [weak self] in self?.update() }
        update()
    }

    private var shows: Bool { view != nil && pane?.model.newTab != nil }

    /// The pane closes while it is a New Tab page: the page discards a chat a chip pick started
    /// behind it, never sent (cx-e2aa). A pane that became a chat keeps its chat.
    public func discardUnsentChat() {
        guard let pane, pane.model.newTab != nil else { return }
        pane.evaluateScript("window.dispatchEvent(new Event('acpmux-newtab-close'))")
    }

    /// Where the page draws: under the bar while it shows, else the whole pane.
    func contentFrame(in bounds: NSRect) -> NSRect {
        guard shows, let pane else { return bounds }
        let inset = min(height, bounds.height)
        return NSRect(x: bounds.minX, y: pane.isFlipped ? bounds.minY + inset : bounds.minY,
                      width: bounds.width, height: bounds.height - inset)
    }

    /// The page became a New Tab page or a chat: the bar shows or leaves, and a bar that leaves
    /// with the keyboard gives it to the page.
    func update() {
        guard let pane, let bar = view else { return }
        if !shows, let window = pane.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: bar) {
            window.makeFirstResponder(pane.webView)
        }
        bar.isHidden = !shows
        bar.autoresizingMask = [.width, pane.isFlipped ? .maxYMargin : .minYMargin]
        bar.frame = NSRect(x: pane.bounds.minX, y: pane.isFlipped ? pane.bounds.minY : pane.bounds.maxY - height,
                           width: pane.bounds.width, height: height)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
    }
}

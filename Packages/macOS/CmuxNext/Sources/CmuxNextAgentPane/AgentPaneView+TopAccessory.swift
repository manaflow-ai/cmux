public import AppKit

/// The bar over a New Tab page (cx-e2aa, Lawrence 2026-10-09: "we should show the omnibar in new
/// tab page"). The App gives the pane its omnibar row once; the pane shows it on top while the page
/// is a New Tab page (spare, adopted, recycled or restored alike) and gives the page the whole pane
/// once it becomes a chat. The bar never covers the page: the page is laid out below it.
extension AgentPaneView {
    /// The bar the App put over the page, shown or not.
    public var topAccessory: NSView? { topBar.view }
    /// Puts `view` (nil: none) over the page, `height` points tall, while the page is a New Tab page.
    public func setTopAccessory(_ view: NSView?, height: CGFloat) {
        topBar.install(view, height: height, in: self)
        model.onNewTabChange = { [weak self] in self?.newTabChanged() }
        newTabChanged()
    }
    /// Where the page draws: under the bar while it shows, else the whole pane.
    var contentFrame: NSRect { topBar.contentFrame(in: bounds, flipped: isFlipped, shows: model.newTab != nil) }
    func newTabChanged() { topBar.update(shows: model.newTab != nil, in: self, keyboardTo: webView) }
}

/// The bar, its height, and where it and the page go (a value of the pane, AgentPaneView.topBar).
struct TopAccessorySlot {
    private(set) var view: NSView?
    private(set) var height: CGFloat = 0

    mutating func install(_ bar: NSView?, height: CGFloat, in pane: NSView) {
        if view !== bar { view?.removeFromSuperview() }
        view = bar
        self.height = max(0, height)
        if let bar, bar.superview !== pane { pane.addSubview(bar) }
    }

    func contentFrame(in bounds: NSRect, flipped: Bool, shows newTab: Bool) -> NSRect {
        guard view != nil, newTab else { return bounds }
        let inset = min(height, bounds.height)
        return NSRect(x: bounds.minX, y: flipped ? bounds.minY + inset : bounds.minY, width: bounds.width, height: bounds.height - inset)
    }

    /// Lays the bar out on top of `pane` (the pane's `layout`).
    @MainActor func layout(in pane: NSView, shows newTab: Bool) {
        guard let bar = view, newTab else { return }
        let inset = min(height, pane.bounds.height)
        bar.frame = NSRect(x: pane.bounds.minX, y: pane.isFlipped ? pane.bounds.minY : pane.bounds.maxY - inset,
                           width: pane.bounds.width, height: inset)
    }

    /// The page became a New Tab page or a chat: the bar shows or leaves, and a bar that leaves
    /// with the keyboard gives it to `page`.
    @MainActor func update(shows newTab: Bool, in pane: NSView, keyboardTo page: NSView) {
        guard let bar = view else { return }
        if !newTab, let window = pane.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: bar) {
            window.makeFirstResponder(page)
        }
        bar.isHidden = !newTab
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
    }
}

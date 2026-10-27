public import AppKit
public import CmuxNextDesign

// R109 `tabs.barOrder`: an empty band between the toolbar rows and the page
// that the pane pins its tab strip to (`PaneHeaderBandHosting`).
extension BrowserChromeView: PaneHeaderBandHosting {
    public func setPaneHeaderBandHeight(_ height: CGFloat) {
        let height = max(0, height)
        guard let constraint = headerBand.height, constraint.constant != height else { return }
        constraint.constant = height
        needsLayout = true
    }

    public var paneHeaderBandGuide: NSLayoutGuide { headerBand.guide }

    /// Lays out first: a browser outside a window (a tab switched away)
    /// gets no layout pass of its own, so the guide's frame would be stale.
    public var paneHeaderBandRect: CGRect {
        // sync-layout: the getter returns the guide's laid-out frame.
        layoutSubtreeIfNeeded()
        return headerBand.guide.frame
    }

    public var onPaneHeaderBandRelease: (() -> Void)? {
        get { headerBand.onRelease }
        set { headerBand.onRelease = newValue }
    }

    public var onPaneHeaderBandReattach: (() -> Void)? {
        get { headerBand.onReattach }
        set { headerBand.onReattach = newValue }
    }

    public var paneHeaderAccessibilityElements: [Any] { [toolbar, accessoryBar] }

    public var paneContentAccessibilityElements: [Any] { [contentContainer] }

    /// The empty band between the toolbar rows and the page (under them, or
    /// above them with the toolbar at the bottom); 0 high until a pane opens it.
    /// The rows are framed (`BrowserChromeLayout`); the guide stays a layout
    /// guide because the pane pins its strip to it, so its offset from the
    /// toolbar's edge follows the rows (`syncHeaderBand`).
    func installHeaderBand() {
        let guide = headerBand.guide
        addLayoutGuide(guide)
        let height = guide.heightAnchor.constraint(equalToConstant: 0)
        headerBand.height = height
        headerBand.top = guide.topAnchor.constraint(equalTo: topAnchor)
        headerBand.bottom = guide.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
        syncHeaderBand(animated: false)
    }

    /// Puts the band after the toolbar and accessory rows, from the toolbar's
    /// edge. `animated`: inside the toolbar's hide or show animation, so a
    /// strip pinned to the band moves with the rows.
    func syncHeaderBand(animated: Bool) {
        guard let top = headerBand.top, let bottom = headerBand.bottom else { return }
        let atTop = toolbarPosition == .top
        let (active, inactive) = atTop ? (top, bottom) : (bottom, top)
        if inactive.isActive { inactive.isActive = false }
        let offset = BrowserChromeLayout.bandOffset(toolbarHeight: toolbarRowHeight, accessoryHeight: shownAccessoryHeight)
        let constant = atTop ? offset : -offset
        if active.constant != constant {
            // Outside a window no display runs the animation, so the constant is set directly.
            (animated && window != nil ? Motion.animator(active, in: self) : active).constant = constant
        }
        if !active.isActive { active.isActive = true }
    }

    /// Constraints from the pane to the band end before this view leaves
    /// its superview or window, on every path (v4 review): the pane's own
    /// detach, a renderer swap, a tab-type swap.
    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { headerBand.onRelease?() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil { headerBand.onRelease?() }
        super.viewWillMove(toWindow: newWindow)
    }

    // Back in a superview inside a window: the pane may pin again
    // (`viewDidMoveToWindow` in BrowserChromeView+Extensions also calls it).
    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        headerBandReattachIfInstalled()
        syncPageOverlays() // a move to another pane in the same window
    }

    func headerBandReattachIfInstalled() {
        if window != nil, superview != nil { headerBand.onReattach?() }
    }
}

/// The band's guide, its constraints and release callback.
final class BrowserHeaderBand {
    let guide = NSLayoutGuide()
    var height: NSLayoutConstraint?
    /// The guide's offset from the view's top (toolbar on top) or bottom (toolbar at the bottom).
    var top: NSLayoutConstraint?
    var bottom: NSLayoutConstraint?
    var onRelease: (() -> Void)?
    var onReattach: (() -> Void)?
}

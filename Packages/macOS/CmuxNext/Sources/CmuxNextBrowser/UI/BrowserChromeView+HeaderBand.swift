public import AppKit
public import CmuxNextDesign

// R109 `tabs.barOrder` below the toolbar: an empty band under the toolbar
// rows that the pane pins its tab strip to (`PaneHeaderBandHosting`).
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
        layoutSubtreeIfNeeded()
        return headerBand.guide.frame
    }

    public var onPaneHeaderBandRelease: (() -> Void)? {
        get { headerBand.onRelease }
        set { headerBand.onRelease = newValue }
    }

    public var paneHeaderAccessibilityElements: [Any] { [toolbar, accessoryBar] }

    public var paneContentAccessibilityElements: [Any] { [contentContainer] }

    /// The empty band under the toolbar rows; 0 high until a pane opens it.
    func installHeaderBand(below bar: NSView) {
        let guide = headerBand.guide
        addLayoutGuide(guide)
        let height = guide.heightAnchor.constraint(equalToConstant: 0)
        headerBand.height = height
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: bar.bottomAnchor),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
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
}

/// The band's guide, height constraint and release callback.
final class BrowserHeaderBand {
    let guide = NSLayoutGuide()
    var height: NSLayoutConstraint?
    var onRelease: (() -> Void)?
}

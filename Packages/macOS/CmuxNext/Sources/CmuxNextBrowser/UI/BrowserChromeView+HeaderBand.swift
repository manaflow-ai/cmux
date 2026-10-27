public import AppKit
public import CmuxNextDesign

// R109 `tabs.barOrder`: an empty band between the toolbar rows and the page
// that the pane frames its tab strip on (`PaneHeaderBandHosting`).
extension BrowserChromeView: PaneHeaderBandHosting {
    public func setPaneHeaderBandHeight(_ height: CGFloat) {
        let height = max(0, height)
        guard headerBand.height != height else { return }
        headerBand.height = height
        // invalidate: the band's row in the layout changed (`chromeLayout`).
        needsLayout = true
    }

    /// The band's row of `chromeLayout`, the same frame computation `layout()` places the rows
    /// from, so it is current before this view's next layout pass (a browser outside a window).
    public var paneHeaderBandRect: CGRect { chromeFrameMapping.map(chromeLayout.band) }

    public var onPaneHeaderBandLayout: ((CGRect) -> Void)? {
        get { headerBand.onLayout }
        set { headerBand.onLayout = newValue }
    }

    /// The end of a layout pass (`layout()`): `band` is the band's row of that pass, so the pane
    /// frames its strip in the same pass and animation group as the rows (a toolbar hide included).
    func reportHeaderBandLayout(_ band: CGRect) {
        headerBand.onLayout?(band)
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

    /// The pane stops framing its strip on the band before this view leaves
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

    // Back in a superview inside a window: the pane may take the band again
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

/// The band's height (a row of `BrowserChromeLayout`, placed with the others in `layout()`) and
/// the pane's callbacks.
final class BrowserHeaderBand {
    /// 0 until a pane opens the band.
    var height: CGFloat = 0
    var onLayout: ((CGRect) -> Void)?
    var onRelease: (() -> Void)?
    var onReattach: (() -> Void)?
}

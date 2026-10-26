import AppKit
import CmuxNextPages

/// Where the spare waits: in the target window (WebKit renders only views in
/// a window and not hidden), fully transparent, never hit by the mouse, and
/// out of the accessibility tree. Adopting the spare reparents it into a pane.
final class NewTabSpareParking: NSView {
    /// The size of the pane content the spare will fill (nil: the window content's), far
    /// outside the window content. A web view's tracking areas ignore alpha and hit testing:
    /// parked over the content, the spare's cards hovered and set the cursor under the tab in
    /// front of it.
    static func frame(in bounds: NSRect, size: NSSize?) -> NSRect {
        NSRect(origin: NSPoint(x: bounds.minX - 100_000, y: bounds.minY - 100_000), size: size ?? bounds.size)
    }

    /// Sizes the parking view and the spare in it to `size` and lays them out now.
    func fit(to size: NSSize) {
        guard let superview else { return }
        frame = Self.frame(in: superview.bounds, size: size)
        for view in subviews where view.frame != bounds { view.frame = bounds }
        layoutSubtreeIfNeeded()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    #if DEBUG || CMUX_BENCH_HOOKS
    // `debug.webui`: the spare's page (on the page host) is hidden to the person while parked.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        PageWebView.noteCensusParked(true, in: subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        PageWebView.noteCensusParked(false, in: subview)
    }
    #endif
}

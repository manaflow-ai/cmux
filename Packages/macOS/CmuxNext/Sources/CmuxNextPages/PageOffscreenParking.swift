public import AppKit

/// Where a prewarmed page waits before it is adopted (the New Tab spare's parking): in the
/// target window (WebKit renders only views in a window and not hidden), far outside the window
/// content, fully transparent, never hit by the mouse, and out of the accessibility tree.
/// Adopting the page reparents it into a pane.
///
/// Its alpha is only to keep the page out of sight, so it does not hide a Chromium page in it
/// (``PageWebView/setChromiumVisibility(_:)``): a Chromium page's child window ignores alpha and
/// keeps drawing, off screen, so adopting it shows a page that already painted. Hidden by its
/// alpha, a parked Chromium spare never painted, and each Cmd-T waited for the pane's 500 ms
/// paint-hold limit.
@MainActor
public final class PageOffscreenParking: NSView {
    /// The size of the pane content the page will fill (nil: the window content's), far
    /// outside the window content. A web view's tracking areas ignore alpha and hit testing:
    /// parked over the content, the page's cards hovered and set the cursor under the tab in
    /// front of it.
    public static func frame(in bounds: NSRect, size: NSSize?) -> NSRect {
        NSRect(origin: NSPoint(x: bounds.minX - 100_000, y: bounds.minY - 100_000), size: size ?? bounds.size)
    }

    /// Sizes the parking view and the page in it to `size` and lays them out now.
    public func fit(to size: NSSize) {
        guard let superview else { return }
        frame = Self.frame(in: superview.bounds, size: size)
        for view in subviews where view.frame != bounds { view.frame = bounds }
        layoutSubtreeIfNeeded()
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    public required init?(coder: NSCoder) { nil }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public var acceptsFirstResponder: Bool { false }
    override public func accessibilityChildren() -> [Any]? { [] }
}

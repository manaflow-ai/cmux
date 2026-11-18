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

/// The one check of whether anybody can see a page, for every gate that holds a hidden page's
/// work (an agent pane's frame pacer, its state pushes, its crash retry, its chat rows, page
/// health). Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread
/// anyways?" The New Tab spare sat in the key window, not hidden, 100,000 pt off screen at alpha 0,
/// so every gate took it for a page in sight and it got each push a chat in front got.
extension NSView {
    /// Under a parking view: a prewarmed, retired or paint-parked page under ``PageOffscreenParking``,
    /// or the page pool's spare under its parking. Not the registry's spare (``PageWebView/isParkedSpare``,
    /// a page the pool can still claim): a retired page is parked too, and nobody sees either.
    public var isParkedOutOfSight: Bool {
        var view = superview
        while let ancestor = view {
            if ancestor is PageOffscreenParking || ancestor is PageHostParking { return true }
            view = ancestor.superview
        }
        return false
    }

    /// Whether nobody can see this view: out of a window, hidden itself or by an ancestor, in a
    /// covered or minimized window, or parked out of sight once its page `painted`. A parked page
    /// that has not painted counts as seen, so it draws its first frame before it is adopted (a
    /// Cmd-T shows a page that already painted); the adoption is a superview move, and the gates read
    /// this again then.
    public func nobodySees(painted: Bool) -> Bool {
        guard let window else { return true }
        if isHiddenOrHasHiddenAncestor || !window.occlusionState.contains(.visible) { return true }
        return painted && isParkedOutOfSight
    }
}

extension PageWebView {
    /// Whether nobody can see this page (``NSView/nobodySees(painted:)``, with its own first paint).
    public var isUnseen: Bool { nobodySees(painted: hasPainted) }
}

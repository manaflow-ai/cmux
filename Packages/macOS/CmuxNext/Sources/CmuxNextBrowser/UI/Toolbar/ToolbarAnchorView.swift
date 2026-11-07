import AppKit

/// A plain view laid over one control of the toolbar page, at the rect the page reported
/// (`layout`), so the native APIs that open a menu, a bubble or a popup at an `NSView` (Page Info at
/// the chip, the bookmark bubble at the star, a menu under a toolbar button, an extension popup)
/// keep working. It draws nothing and takes no events: every press reaches the page under it.
final class ToolbarAnchorView: NSView {
    /// The control's key in the page's `layout` report (`back`, `chip`, `button:downloads`, ...).
    let key: String

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

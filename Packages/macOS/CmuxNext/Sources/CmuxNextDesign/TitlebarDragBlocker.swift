public import AppKit

/// Marks its frame as taking the mouse inside a full-size-content window's
/// titlebar band, so pressing there never moves the window.
///
/// macOS moves a window by a press-and-drag anywhere in the titlebar band
/// (the top 32 pt of a `fullSizeContentView` window) that no *control*
/// claims; it decides from a region AppKit precomputes, before the app sees
/// the mouse-down. Plain views do not claim it, even with
/// `mouseDownCanMoveWindow` false or their own `mouseDown(with:)`: only an
/// `NSControl` that accepts first responder does (measured on macOS 26 with
/// the theme frame's opaque-descendant region). The window's root places
/// one blocker over the whole band, so the window server never moves the
/// window on its own and `TitlebarDragPolicy` is the only decision. The
/// blocker returns nil from `hitTest(_:)`, so every event still reaches the
/// view under it, and it can never take the keyboard.
public final class TitlebarDragBlocker: NSControl {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var mouseDownCanMoveWindow: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var canBecomeKeyView: Bool { false }
    public override func becomeFirstResponder() -> Bool { false }
    public override func draw(_ dirtyRect: NSRect) {}
}

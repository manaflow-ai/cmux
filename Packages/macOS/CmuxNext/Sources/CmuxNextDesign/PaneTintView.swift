public import AppKit

/// A pane's marker tint (`pane.setTint`): one color layer over the whole pane that takes no
/// clicks and is invisible to accessibility.
public final class PaneTintView: NSView {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

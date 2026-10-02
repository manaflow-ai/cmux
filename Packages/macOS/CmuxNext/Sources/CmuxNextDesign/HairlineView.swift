public import AppKit

/// A separator line for AppKit chrome (use instead of `NSBox.separator`,
/// whose system color ignores the theme scope and `appearance.borders`):
/// it fills with `Palette.separator` in its theme scope, which is clear
/// under borders none, and keeps its size either way.
public final class HairlineView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = performWithTheme { Palette.separator.cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

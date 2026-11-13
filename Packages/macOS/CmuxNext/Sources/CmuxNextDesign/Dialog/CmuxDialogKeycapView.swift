import AppKit

/// The key that presses a dialog button, on a small rounded plate at the button's trailing end ("Not Now esc",
/// "Turn On ↩"; Lawrence 2026-11-09). The plate sits with one inset on its top, bottom and end, and its corners
/// follow the button's: its radius is the button's less that inset (concentric). It takes no clicks: the button
/// under it does.
@MainActor
final class CmuxDialogKeycapView: NSView {
    let label: ChromeLabel

    init(_ glyph: String) {
        label = ChromeLabel(labelWithString: glyph)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Typography.system(.default, size: TypeScale.caption, weight: TypeScale.emphasis)
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// The plate's width for `height`: the glyph and a little room each side, never narrower than square.
    func width(forHeight height: CGFloat) -> CGFloat {
        max(height, ceil(label.naturalSize.width) + CmuxDialogMetrics.keycapPadding * 2)
    }

    /// Colors the plate (the title's ink, faint) and the glyph (the key hint's ink).
    func paint(ink: NSColor, glyph: NSColor) {
        layer?.backgroundColor = ink.withAlphaComponent(0.14).cgColor
        label.textColor = glyph
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = max(0, CmuxDialogMetrics.keycapButtonCornerRadius - CmuxDialogMetrics.keycapInset)
        let size = label.naturalSize
        label.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

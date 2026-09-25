import AppKit

/// The insertion line shared by local workspace rows and the Cloud outline.
@MainActor
final class SidebarReorderIndicatorView: NSView {
    nonisolated static let thickness: CGFloat = 2
    nonisolated static let horizontalInset: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("sidebarReorderIndicator")
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func position(in bounds: NSRect, at y: CGFloat, leadingInset: CGFloat = 0) {
        let leading = Self.horizontalInset + max(0, leadingInset)
        frame = NSRect(
            x: bounds.minX + leading, y: y,
            width: max(0, bounds.width - leading - Self.horizontalInset),
            height: Self.thickness
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    func updateColor() {
        layer?.backgroundColor = cmuxAccentNSColor(
            for: SidebarAppearanceColorResolver().currentColorScheme()
        ).cgColor
    }
}

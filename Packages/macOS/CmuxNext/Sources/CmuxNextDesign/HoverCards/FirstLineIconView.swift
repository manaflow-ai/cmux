public import AppKit

/// A decorative icon on a first-baseline row whose center sits on the middle of `line`'s first
/// line (midway between its ascender and descender). When the text wraps, the icon stays with
/// the first line instead of floating to the middle of the block (Leo 2026-10-21: the workspace
/// card's two-line preview had its icon centered beside both lines).
///
/// A plain `NSImageView` reports no baseline, so a first-baseline stack hangs it from the
/// text's baseline; this one reports where its center belongs.
@MainActor
public final class FirstLineIconView: NSImageView {
    /// The text whose first line the icon sits on.
    public weak var line: ChromeLabel?
    /// The icon's height (its constraint), not `bounds`, which is zero before the first layout.
    public var side: CGFloat

    public init(side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        // Decorative: the row's text says it (an image view answers through its cell).
        cell?.setAccessibilityElement(false)
    }

    /// AppKit's own path (`initWithFrame:`): a side the size of the frame's height.
    public override init(frame: NSRect) {
        side = frame.height
        super.init(frame: frame)
        cell?.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func isAccessibilityElement() -> Bool { false }

    public override var firstBaselineOffsetFromTop: CGFloat {
        guard let font = line?.font else { return super.firstBaselineOffsetFromTop }
        return Self.baselineOffset(side: side, font: font)
    }

    /// How far below its top a mark `side` tall puts the baseline so its center sits midway
    /// between `font`'s ascender and descender on that baseline. Pure.
    public static func baselineOffset(side: CGFloat, font: NSFont) -> CGFloat {
        side / 2 + (font.ascender + font.descender) / 2
    }
}

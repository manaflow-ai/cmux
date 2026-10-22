public import AppKit

/// A hover card line's leading icon: decorative (accessibility skips it, its line says it), and on a
/// first-baseline row its center sits on the middle of `line`'s capitals on its first line
/// (`NSFont.iconBaselineOffsetFromTop(iconHeight:)`), so it stays with the first line when the
/// text wraps.
///
/// ```swift
/// let icon = HoverCardIconView(line: titleLabel)
/// let row = NSStackView(views: [icon, titleLabel])
/// row.alignment = .firstBaseline
/// ```
@MainActor
public final class HoverCardIconView: NSImageView {
    /// The text the icon leads; its font sets where the icon sits.
    public weak var line: (any ShownText)?
    /// The icon's height (its constraint), not `bounds`, which is zero before the first layout.
    public var side: CGFloat

    /// An icon `side` points tall leading `line`.
    /// - Parameter side: The icon's height; the hover card rows' icon size by default.
    /// - Parameter line: The text it leads; set it later when the label is made after the icon.
    public init(side: CGFloat = HoverCardRowView.iconSize, line: (any ShownText)? = nil) {
        self.side = side
        self.line = line
        super.init(frame: .zero)
        cell?.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func isAccessibilityElement() -> Bool { false }

    public override var firstBaselineOffsetFromTop: CGFloat {
        guard let font = line?.font else { return super.firstBaselineOffsetFromTop }
        return font.iconBaselineOffsetFromTop(iconHeight: side)
    }
}

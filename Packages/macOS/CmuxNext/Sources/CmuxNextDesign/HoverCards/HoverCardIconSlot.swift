public import AppKit

/// A box `side` points square that holds a hover card line's leading mark (a status indicator),
/// placed like `HoverCardIconView` on a first-baseline row: its center on the middle of `line`'s
/// capitals on its first line. The slot never hides, so a mark that draws nothing keeps the text
/// on the card's text column.
@MainActor
public final class HoverCardIconSlot: NSView {
    /// The text the mark leads; its font sets where the slot sits.
    public weak var line: (any ShownText)?
    /// The slot's height (its constraint), not `bounds`, which is zero before the first layout.
    public var side: CGFloat

    /// A slot `side` points tall leading `line`.
    /// - Parameter side: The slot's height; the hover card rows' icon size by default.
    /// - Parameter line: The text the mark leads.
    public init(side: CGFloat = HoverCardRowView.iconSize, line: (any ShownText)? = nil) {
        self.side = side
        self.line = line
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var firstBaselineOffsetFromTop: CGFloat {
        guard let font = line?.font else { return super.firstBaselineOffsetFromTop }
        return font.iconBaselineOffsetFromTop(iconHeight: side)
    }
}

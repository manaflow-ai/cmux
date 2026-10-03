import CoreGraphics
import CoreText

/// Measured style metrics of the reference design (points; the reference
/// viewport is 628 pt wide).
enum Style {
    static let referenceWidth: CGFloat = 628
    static let bodySize: CGFloat = 13
    static let lineHeight: CGFloat = 16
    /// Body text is drawn about 0.27% tighter than Core Text's default advances.
    static let bodyKern: CGFloat = -0.0028
    static let bubblePadX: CGFloat = 12
    static let bubblePadY: CGFloat = 7
    static let bubbleRadius: CGFloat = 15
    /// First baseline below the bubble top.
    static let textBaseline: CGFloat = 20
    static let leftEdge: CGFloat = 20
    static let rightInset: CGFloat = 20
    static let receiptInset: CGFloat = 35.8
    static let labelLeft: CGFloat = 32
    /// The text column at the reference width; it grows in proportion.
    static let maxTextWidth: CGFloat = 358.4
    static let captionSize: CGFloat = 10
    static let captionKern: CGFloat = -0.03
    /// A line after a hard newline advances 15.5 pt in a sent bubble (16 pt
    /// for received text and wrapped lines).
    static let hardBreakAdvance: CGFloat = 15.5
    /// Rows are drawn with this margin above and below their content (tails,
    /// tapback badges reach 22 pt above a bubble).
    static let rowMargin: CGFloat = 24
    /// Space the bubble art keeps left and right of the body (failed badge,
    /// tapback tails, the outgoing tail).
    static let artLeft: CGFloat = 36
    static let artRight: CGFloat = 20

    @MainActor static let bodyFont = Fonts.system(bodySize)
}

/// Width-dependent geometry. At the reference width every value equals the
/// measured constant; wider viewports move right-aligned content with the
/// right edge and grow the text column in proportion.
struct Metrics: Hashable, Sendable {
    var width: CGFloat

    var rightEdge: CGFloat { width - Style.rightInset }
    var centerX: CGFloat { width / 2 - 0.1 }
    var receiptRight: CGFloat { width - Style.receiptInset }
    /// Rounded to 0.1 pt so tiny width changes keep the same wrap width.
    var maxTextWidth: CGFloat { (Style.maxTextWidth * width / Style.referenceWidth * 10).rounded() / 10 }
}

extension CGFloat {
    /// Snapped to the 2x device pixel grid.
    var px: CGFloat { (self * 2).rounded() / 2 }
}

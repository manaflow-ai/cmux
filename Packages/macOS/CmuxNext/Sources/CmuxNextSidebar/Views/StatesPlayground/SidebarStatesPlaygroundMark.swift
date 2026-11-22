import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one trailing mark a real row laid out (a dot, the
/// spinner, a status mark, the chevron, a button), as measured, never from a constant.
struct SidebarStatesPlaygroundMark: Equatable, Sendable {
    /// What drew the mark: the view's class name (`StatusIndicatorView`, `UnreadBadgeView`, ...).
    var view: String
    /// The status the mark draws, for a status indicator (`working`, `success`, ...); nil for others.
    var state: String?
    /// The frame the row's layout gave the mark's view, in the cell's points (top-left origin).
    var frame: CGRect
    /// The box of the pixels the mark inked, in points; nil when nothing differed from the row behind it.
    var ink: CGSize?

    /// "14 / 9.5 pt": the frame's side (or width × height), then the ink's, for the cell's caption.
    var sizeText: String {
        let frameText = Self.text(frame.size)
        guard let ink else { return frameText }
        return "\(frameText) / \(Self.text(ink))"
    }

    /// A size in points: one number for a square, else width × height; at most one decimal.
    static func text(_ size: CGSize) -> String {
        abs(size.width - size.height) < 0.05 ? number(size.width) : "\(number(size.width))×\(number(size.height))"
    }

    /// A length in points, at most one decimal.
    static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", Double(rounded))
    }
}

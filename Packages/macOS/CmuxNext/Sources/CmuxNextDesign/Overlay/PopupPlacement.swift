public import AppKit

/// Where a page's menu goes once it has no room in its web view (cx-6k6cg): like a Mac menu, on
/// the screen past the window's edge. Below the anchor when it fits on the screen, else above,
/// else on the side with more room, shortened so its rows scroll. Screen coordinates (y up).
public nonisolated struct PopupPlacement {
    public nonisolated init() {}
    public enum Side: String, Sendable { case below, above }

    /// The horizontal side used by a submenu that opens beside its parent row.
    public enum HorizontalSide: String, Sendable { case right, left }

    /// The popup's frame on `screen` (its visible frame) for content of `size` at `anchor`.
    /// `preferred` is the side the page asked for; `trailing` aligns the popup's trailing edge
    /// with the anchor's instead of its leading edge, and `centered` (over `trailing`) centers
    /// it on the anchor, as an `NSPopover` sits under the control it opens from.
    public static func frame(anchor: CGRect, size: CGSize, preferred: Side, trailing: Bool = false, centered: Bool = false,
                             screen: CGRect, gap: CGFloat = 4, margin: CGFloat = 6) -> (frame: CGRect, side: Side) {
        let roomBelow = anchor.minY - gap - (screen.minY + margin)
        let roomAbove = (screen.maxY - margin) - (anchor.maxY + gap)
        let order: [Side] = preferred == .below ? [.below, .above] : [.above, .below]
        let room: (Side) -> CGFloat = { $0 == .below ? roomBelow : roomAbove }
        let side = order.first { room($0) >= size.height } ?? (roomBelow >= roomAbove ? .below : .above)
        let height = max(0, min(size.height, room(side)))
        let width = min(size.width, screen.width - 2 * margin)
        let y = side == .below ? anchor.minY - gap - height : anchor.maxY + gap
        // A centered card starts on a whole point, so `integral` never widens it past its content.
        let leading = centered ? (anchor.midX - width / 2).rounded() : trailing ? anchor.maxX - width : anchor.minX
        let x = min(max(screen.minX + margin, leading), screen.maxX - margin - width)
        return (CGRect(x: x, y: y, width: width, height: height).integral, side)
    }

    /// The frame for a submenu opened beside its parent row. It prefers the right side and
    /// flips to the left when the card would not fit; its vertical position follows the row and
    /// is clamped to the visible screen. The returned side is useful for diagnostics and tests.
    public static func sideBySideFrame(anchor: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 4,
                                       margin: CGFloat = 6) -> (frame: CGRect, side: HorizontalSide) {
        let width = min(size.width, screen.width - 2 * margin)
        let roomRight = screen.maxX - margin - anchor.maxX - gap
        let roomLeft = anchor.minX - gap - (screen.minX + margin)
        let side: HorizontalSide = roomRight >= width || roomRight >= roomLeft ? .right : .left
        let rawX = side == .right ? anchor.maxX + gap : anchor.minX - gap - width
        let x = min(max(screen.minX + margin, rawX), screen.maxX - margin - width)
        let height = min(size.height, screen.height - 2 * margin)
        let rawY = anchor.maxY - height
        let y = min(max(screen.minY + margin, rawY), screen.maxY - margin - height)
        return (CGRect(x: x, y: y, width: width, height: height).integral, side)
    }

    /// The screen a popup at `anchor` belongs on: the one holding the anchor's center, else
    /// `fallback`'s, else the main screen.
    @MainActor
    public static func screen(for anchor: CGRect, fallback: NSWindow?) -> NSScreen? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? fallback?.screen ?? NSScreen.main
    }
}

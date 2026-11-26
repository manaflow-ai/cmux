public import CoreGraphics

/// Where an agent cursor's name tag sits around the arrow tip so it never
/// leaves the visible page (user, 2026-10-21: "place the tooltip such that it
/// doesnt overflow out the page"). The tag rests below-right of the tip; near
/// the right edge it flips to the left of the tip, near the bottom edge above
/// it, and it is then clamped into the page. A flip back needs
/// ``hysteresis`` points of room to spare, so a cursor moving along an edge
/// does not make the tag jump from side to side.
nonisolated public struct AgentCursorTagLayout: Sendable, Equatable {
    /// The gap the tag keeps from the page's edges.
    public static let margin: CGFloat = 4
    /// The room a flipped tag needs on its resting side before it flips back.
    public static let hysteresis: CGFloat = 24
    /// The resting tag's top-left corner from the tip: in the hollow behind the
    /// arrow's notch, so it never covers the tip or the body.
    public static let restingOffset = CGPoint(x: 7, y: 14)
    /// The gap between the tag and the caption under or over it.
    public static let captionGap: CGFloat = 4
    /// The gap between the tip and a tag flipped left of it.
    static let leadingGap: CGFloat = 6
    /// The gap between the tip and a tag flipped above it.
    static let aboveGap: CGFloat = 6

    /// The tag sits left of the tip.
    public var leading: Bool
    /// The tag sits above the tip.
    public var above: Bool

    /// - Parameters:
    ///   - leading: The tag sits left of the tip.
    ///   - above: The tag sits above the tip.
    public init(leading: Bool = false, above: Bool = false) {
        self.leading = leading
        self.above = above
    }

    /// The resting layout: below-right of the tip.
    public static let resting = AgentCursorTagLayout()

    /// The layout for a tag of `size` at `tip` inside `bounds`, starting from
    /// this one: a side flips when the tag would overflow, and flips back only
    /// with ``hysteresis`` to spare.
    /// - Parameters:
    ///   - size: The tag's size.
    ///   - tip: The arrow tip, in the coordinates of `bounds`.
    ///   - bounds: The visible page.
    /// - Returns: The layout to draw with.
    public func next(size: CGSize, tip: CGPoint, bounds: CGRect) -> AgentCursorTagLayout {
        let inner = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        // How far each side's tag would stick out of the page (negative: room to spare).
        let pastRight = tip.x + Self.restingOffset.x + size.width - inner.maxX
        let pastLeft = inner.minX - (tip.x - Self.leadingGap - size.width)
        let pastBottom = tip.y + Self.restingOffset.y + size.height - inner.maxY
        let pastTop = inner.minY - (tip.y - Self.aboveGap - size.height)
        return AgentCursorTagLayout(
            leading: Self.flips(leading, pastResting: pastRight, pastFlipped: pastLeft),
            above: Self.flips(above, pastResting: pastBottom, pastFlipped: pastTop)
        )
    }

    /// Whether one axis sits flipped: it flips when the resting side overflows
    /// and the flipped side overflows less; it returns when the resting side has
    /// ``hysteresis`` to spare or the flipped side overflows more.
    private static func flips(_ flipped: Bool, pastResting: CGFloat, pastFlipped: CGFloat) -> Bool {
        if flipped {
            return !(pastResting <= -hysteresis || (pastFlipped > 0 && pastFlipped > pastResting))
        }
        return pastResting > 0 && pastFlipped < pastResting
    }

    /// The tag's frame for this layout, in the coordinates of `bounds`,
    /// clamped inside `bounds` (a tag wider than the page starts at its left edge).
    /// - Parameters:
    ///   - size: The tag's size.
    ///   - tip: The arrow tip.
    ///   - bounds: The visible page; nil places the tag unclamped.
    public func frame(size: CGSize, tip: CGPoint, bounds: CGRect?) -> CGRect {
        let x = leading ? tip.x - Self.leadingGap - size.width : tip.x + Self.restingOffset.x
        let y = above ? tip.y - Self.aboveGap - size.height : tip.y + Self.restingOffset.y
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard let bounds else { return frame }
        return Self.clamp(frame, into: bounds.insetBy(dx: Self.margin, dy: Self.margin))
    }

    /// The caption's frame (what the agent types): beside the tag, away from
    /// the tip (under a tag below the tip, over a tag above it), its edge flush
    /// with the tag's on the tag's side, clamped inside `bounds`.
    /// - Parameters:
    ///   - size: The caption's size.
    ///   - tag: The tag's frame, or nil without a tag (the caption takes its place).
    ///   - tip: The arrow tip.
    ///   - bounds: The visible page; nil places the caption unclamped.
    public func captionFrame(size: CGSize, tag: CGRect?, tip: CGPoint, bounds: CGRect?) -> CGRect {
        guard let tag else { return frame(size: size, tip: tip, bounds: bounds) }
        let gap = Self.captionGap
        let x = leading ? tag.maxX - size.width : tag.minX
        let y = above ? tag.minY - gap - size.height : tag.maxY + gap
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard let bounds else { return frame }
        return Self.clamp(frame, into: bounds.insetBy(dx: Self.margin, dy: Self.margin))
    }

    private static func clamp(_ frame: CGRect, into inner: CGRect) -> CGRect {
        guard !inner.isNull, inner.width > 0, inner.height > 0 else { return frame }
        var origin = frame.origin
        origin.x = max(min(origin.x, inner.maxX - frame.width), inner.minX)
        origin.y = max(min(origin.y, inner.maxY - frame.height), inner.minY)
        return CGRect(origin: origin, size: frame.size)
    }
}

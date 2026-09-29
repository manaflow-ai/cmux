public import CmuxNextLayout
public import CoreGraphics

/// Motion model of the drag ghost. The ghost tracks the pointer with zero
/// lag, and every discontinuous change (card -> inline tab, a new strip
/// slot, spring back, drop) animates: the presented rect is the target plus
/// an offset that springs to zero, so a jump never teleports the ghost and
/// pointer motion is never smoothed away.
public nonisolated struct TabDragGhostMotion: Sendable, Equatable {
    /// The tab image's screen rect the ghost is heading to.
    public private(set) var targetRect: CGRect
    private var dx = SpringValue(0)
    private var dy = SpringValue(0)
    private var dw = SpringValue(0)
    private var dh = SpringValue(0)
    /// 0 = inline tab, 1 = floating preview card.
    private var cardness: SpringValue
    private var opacity = SpringValue(1)
    private var scale = SpringValue(1)
    public var reduceMotion: Bool

    public static let rectSpring = SpringParameters(response: 0.22, dampingFraction: 0.84)
    public static let morphSpring = SpringParameters(response: 0.26, dampingFraction: 1)

    public init(rect: CGRect, cardness: CGFloat, reduceMotion: Bool = false) {
        targetRect = rect
        self.cardness = SpringValue(cardness)
        self.reduceMotion = reduceMotion
    }

    public var presentedRect: CGRect {
        CGRect(x: targetRect.minX + dx.value, y: targetRect.minY + dy.value,
               width: max(1, targetRect.width + dw.value), height: max(1, targetRect.height + dh.value))
    }

    public var presentedCardness: CGFloat { min(max(cardness.value, 0), 1) }
    public var presentedOpacity: CGFloat { min(max(opacity.value, 0), 1) }
    public var presentedScale: CGFloat { max(scale.value, 0.01) }

    /// Moves the target. `jump` marks a discontinuity (new mode, slot, or
    /// destination): the presented rect stays where it is and springs over.
    /// Without `jump` the ghost follows the target exactly.
    public mutating func setTarget(_ rect: CGRect, cardness: CGFloat, opacity: CGFloat = 1, scale: CGFloat = 1, jump: Bool) {
        if jump {
            let presented = presentedRect
            dx.value = presented.minX - rect.minX
            dy.value = presented.minY - rect.minY
            dw.value = presented.width - rect.width
            dh.value = presented.height - rect.height
        }
        targetRect = rect
        self.cardness.target = cardness
        self.opacity.target = opacity
        self.scale.target = scale
        if reduceMotion { snap() }
    }

    /// Advances by `dt` seconds. Returns true while anything still moves.
    public mutating func step(_ dt: Double) -> Bool {
        if reduceMotion {
            snap()
            return false
        }
        var moving = false
        for keyPath in [\Self.dx, \.dy, \.dw, \.dh] where self[keyPath: keyPath].advance(dt, parameters: Self.rectSpring, epsilon: 0.25) {
            moving = true
        }
        if cardness.advance(dt, parameters: Self.morphSpring, epsilon: 0.002) { moving = true }
        if opacity.advance(dt, parameters: Self.morphSpring, epsilon: 0.002) { moving = true }
        if scale.advance(dt, parameters: Self.morphSpring, epsilon: 0.002) { moving = true }
        return moving
    }

    public var isSettled: Bool {
        [dx, dy, dw, dh].allSatisfy { $0.value == $0.target && $0.velocity == 0 }
            && [cardness, opacity, scale].allSatisfy { $0.value == $0.target && $0.velocity == 0 }
    }

    public mutating func snap() {
        dx.snap(); dy.snap(); dw.snap(); dh.snap()
        cardness.snap(); opacity.snap(); scale.snap()
    }
}

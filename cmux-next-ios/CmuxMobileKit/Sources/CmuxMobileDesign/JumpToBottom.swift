import CoreGraphics

/// Whether a transcript's jump-to-bottom control shows (verify/jump-button.md).
///
/// Distances come from the offset clamped to the scrollable range, so the
/// rubber band never counts: pulling an empty or short chat down moved the
/// offset 100+ pt above the top, which read as "100 pt from the bottom" and
/// flashed the button over the composer (user recording, iOS 27 device).
/// It shows past `showDistance` and hides inside `hideDistance`, so jitter
/// near the threshold never toggles it, and an interactive keyboard
/// dismissal (the finger pulling the keyboard down) never brings it up.
public struct JumpToBottomVisibility: Equatable, Sendable {
    public static let showDistance: CGFloat = 120
    public static let hideDistance: CGFloat = 48

    public private(set) var isShown: Bool

    public init(isShown: Bool = false) {
        self.isShown = isShown
    }

    /// The distance from the bottom that counts: the offset clamped to
    /// `minOffsetY...maxOffsetY` (top inset to the newest turn).
    public static func distance(offsetY: CGFloat, minOffsetY: CGFloat, maxOffsetY: CGFloat) -> CGFloat {
        let top = min(minOffsetY, maxOffsetY)
        return maxOffsetY - min(max(offsetY, top), maxOffsetY)
    }

    /// Updates `isShown` for a scroll position and returns it.
    @discardableResult
    public mutating func update(offsetY: CGFloat, minOffsetY: CGFloat, maxOffsetY: CGFloat,
                                keyboardDragging: Bool = false) -> Bool {
        isShown = Self.next(isShown: isShown, offsetY: offsetY, minOffsetY: minOffsetY, maxOffsetY: maxOffsetY,
                            keyboardDragging: keyboardDragging)
        return isShown
    }

    public static func next(isShown: Bool, offsetY: CGFloat, minOffsetY: CGFloat, maxOffsetY: CGFloat,
                            keyboardDragging: Bool = false) -> Bool {
        let away = distance(offsetY: offsetY, minOffsetY: minOffsetY, maxOffsetY: maxOffsetY)
        if isShown { return away > hideDistance }
        if keyboardDragging { return false }
        return away > showDistance
    }
}

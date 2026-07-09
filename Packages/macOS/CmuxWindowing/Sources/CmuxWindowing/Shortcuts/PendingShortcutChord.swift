/// The first stroke of a two-stroke (chorded) configured shortcut that has been
/// matched and is now waiting for its second stroke.
///
/// A chord is window-scoped: the second stroke only completes the chord when it
/// arrives in the same window that received the first stroke (identified by its
/// AppKit `windowNumber`). A stroke landing in a different window leaves this
/// prefix inactive, so a half-typed chord in one window never swallows a
/// keystroke in another (the legacy behavior this preserves).
///
/// `Stroke` is generic so the package never names the app target's
/// `ShortcutStroke` value type (the app keeps its own stroke representation and
/// its NSEvent-matching logic; this type only carries one across the gap
/// between two key events).
public struct PendingShortcutChord<Stroke: Equatable & Sendable>: Sendable, Equatable {
    /// The first stroke that matched, awaiting its completing second stroke.
    public let firstStroke: Stroke

    /// The AppKit `windowNumber` of the window the first stroke landed in, or
    /// `nil` when no window could be resolved for the originating event.
    public let windowNumber: Int?

    /// Creates a pending chord prefix scoped to `windowNumber`.
    public init(firstStroke: Stroke, windowNumber: Int?) {
        self.firstStroke = firstStroke
        self.windowNumber = windowNumber
    }
}

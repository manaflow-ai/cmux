import CoreGraphics

/// A ``ThinScroller``'s knob slot and knob along its axis, measured from the top (a sideways
/// scroller's: from the leading end): the press and drag math, pure so it is tested without events.
///
/// A drag keeps the point of the knob it grabbed under the pointer, so the knob moves with the
/// pointer point for point (``value(knobStart:)``), wherever the pointer goes across the bar.
struct ThinScrollerTrack: Equatable {
    /// Where a press along the axis lands.
    enum Part: Equatable {
        /// The slot before the knob (above it, or left of it).
        case before
        /// The knob.
        case knob
        /// The slot after the knob (below it, or right of it).
        case after
    }

    var slotStart: CGFloat
    var slotLength: CGFloat
    var knobStart: CGFloat
    var knobLength: CGFloat

    /// How far the knob's start can move along the slot.
    var travel: CGFloat { max(0, slotLength - knobLength) }

    /// The part at `position` along the axis.
    func part(at position: CGFloat) -> Part {
        if position < knobStart { return .before }
        return position < knobStart + knobLength ? .knob : .after
    }

    /// The scroller value (0 at the top, 1 at the end) that puts the knob's start at `start`, clamped.
    func value(knobStart start: CGFloat) -> Double {
        guard travel > 0 else { return 0 }
        return Double(min(max((start - slotStart) / travel, 0), 1))
    }

    /// The value that centers the knob on `position` (a press that jumps to the clicked spot).
    func value(centeredAt position: CGFloat) -> Double {
        value(knobStart: position - knobLength / 2)
    }
}

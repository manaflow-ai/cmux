public import Foundation

/// A `Sendable`, AppKit-free description of the pane flash opacity keyframe
/// animation.
///
/// The app target owns `FocusFlashPattern` (the curve/keytime source of truth);
/// it lowers that pattern into this primitive spec and hands it to the overlay
/// container, which builds the `CAKeyframeAnimation` from it. Keeping the spec
/// here lets the view layer animate without importing the app-target pattern.
public struct TerminalPaneFlashAnimationSpec: Sendable, Equatable {
    /// One easing curve per keyframe segment.
    public enum Curve: Sendable, Equatable {
        case easeIn
        case easeOut
    }

    /// Opacity values at each keyframe stop.
    public var values: [Double]
    /// Normalized key times (`0...1`) matching ``values``.
    public var keyTimes: [Double]
    /// Total animation duration in seconds.
    public var duration: TimeInterval
    /// Easing curves, one per segment between keyframe stops.
    public var curves: [Curve]

    /// Creates a flash animation spec from primitive keyframe values.
    public init(
        values: [Double],
        keyTimes: [Double],
        duration: TimeInterval,
        curves: [Curve]
    ) {
        self.values = values
        self.keyTimes = keyTimes
        self.duration = duration
        self.curves = curves
    }
}

public import Foundation

/// One segment of a focus-flash animation: a delayed, timed opacity transition
/// to ``targetOpacity`` using ``curve``.
public struct FocusFlashSegment: Equatable {
    public let delay: TimeInterval
    public let duration: TimeInterval
    public let targetOpacity: Double
    public let curve: FocusFlashCurve

    public init(
        delay: TimeInterval,
        duration: TimeInterval,
        targetOpacity: Double,
        curve: FocusFlashCurve
    ) {
        self.delay = delay
        self.duration = duration
        self.targetOpacity = targetOpacity
        self.curve = curve
    }
}

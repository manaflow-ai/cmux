/// The range of frame rates a display link is asked to fire at, in frames a second: the platform
/// value behind ``FrameLink/requestFrameRate(_:)``, so the schedulers decide a rate without Core
/// Animation. A `CADisplayLink` takes it as its `CAFrameRateRange` (FrameLink+CoreAnimation.swift).
///
/// Chrome keeps the same split: viz decides the display's frame interval as a plain value
/// (`components/viz/service/display/frame_rate_decider.cc`) and only the platform's link maps it to
/// its own type (`ui/display/mac/ca_display_link_mac.mm`, `preferredFrameRateRange`).
public struct FrameRateRange: Sendable, Hashable {
    /// The lowest rate the link may fire at.
    public var minimum: Float
    /// The highest rate the link may fire at.
    public var maximum: Float
    /// The rate it should fire at; nil leaves the system to pick within the range.
    public var preferred: Float?

    public init(minimum: Float, maximum: Float, preferred: Float?) {
        self.minimum = minimum
        self.maximum = maximum
        self.preferred = preferred
    }
}

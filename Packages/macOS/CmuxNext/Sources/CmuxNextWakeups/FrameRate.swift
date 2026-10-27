/// How often a ``FrameClient`` needs frames, and how often a looping Core Animation indicator needs
/// the render server to draw it.
///
/// A display's link runs at the highest rate any of its armed clients asks for (``highest(of:)``),
/// as Chrome's viz picks the display's frame interval from the intervals its frame sinks prefer
/// (`components/viz/service/display/frame_rate_decider.cc`, `FrameRateDecider::UpdatePreferredFrameIntervalIfNeeded`):
/// one ambient spinner alone runs the link at 30 Hz, and a spring that starts beside it brings the
/// link back to the display's full rate.
public enum FrameRate: Sendable, Hashable {
    /// Springs, scrolls, drag autoscroll: every display frame, 80 to 120 Hz on ProMotion.
    case motion
    /// Content that changes every frame but does not move under the pointer: 60 Hz.
    case ui
    /// Spinners, breathing and pulsing indicators, decorative loops: 30 Hz.
    case ambient
    /// `n` frames a second (1 to 30): a discrete indicator (``stepping(_:every:)``). A display
    /// link never runs below ``DisplayClock/slowestLinkHertz``, whatever its clients ask.
    case slow(Int)

    /// Frames a second this rate asks for.
    public var hertz: Float {
        switch self {
        case .motion: 120
        case .ui: 60
        case .ambient: 30
        case .slow(let perSecond): Float(min(max(perSecond, 1), 30))
        }
    }

    /// The range a display link or a `CAAnimation` asks for at this rate (as a `CAFrameRateRange`:
    /// ``range``). A slow rate may run faster (up to 30 Hz), never slower: a display whose refresh `n`
    /// does not divide picks the next rate above.
    public var preferredRange: FrameRateRange {
        switch self {
        case .motion: FrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        case .ui, .ambient: FrameRateRange(minimum: hertz, maximum: hertz, preferred: hertz)
        case .slow: FrameRateRange(minimum: hertz, maximum: FrameRate.ambient.hertz, preferred: hertz)
        }
    }

    /// The highest of `rates` (Chrome's decider takes the shortest preferred interval of the
    /// sinks that draw); nil when there are none.
    public static func highest(of rates: some Sequence<FrameRate>) -> FrameRate? {
        rates.max { $0.hertz < $1.hertz }
    }

    /// The rate of an indicator that changes `steps` times a `period` (seconds): ``slow(_:)`` at
    /// twice that many changes a second, ``ambient`` when that is 30 or more. The steps follow
    /// wall time, not the render server's frames, so at the step rate itself a step boundary that
    /// drifts past a frame shows one step twice and never draws the next; two frames a step draw
    /// every step at least once.
    public static func stepping(_ steps: Int, every period: Double) -> FrameRate {
        guard period > 0 else { return .ambient }
        let perSecond = (2 * Double(steps) / period).rounded(.up)
        return perSecond >= 30 ? .ambient : .slow(Int(perSecond))
    }
}

import Foundation
import Observation

/// How fast the Feed is scrolling, for content that is expensive to show.
///
/// A web-rendered body costs a web view, a JavaScript render and a WebKit
/// layer commit when its row scrolls in; during a fling dozens of rows pass
/// in a second and that work dropped frames (verify/feed-perf-20261021.md).
/// While `isFast`, such rows show a cheap placeholder at their known height;
/// they render when the scroll slows below `slowSpeed` or stops. The two
/// thresholds keep a slowing fling from flickering between the two.
@MainActor
@Observable
final class FeedScrollMotion {
    /// Faster than this (pt/s) is a fling.
    static let fastSpeed: Double = 1500
    /// Slower than this (pt/s) is reading again.
    static let slowSpeed: Double = 600

    private(set) var isFast = false
    @ObservationIgnored private var last: (y: CGFloat, time: Double)?
    /// The person drags or the Feed decelerates from a drag: only then is speed a fling. An offset
    /// change at rest (keyboard avoidance, an inset change, a programmatic scroll) never is.
    @ObservationIgnored var isScrolling = false

    /// The scroll offset at a frame's time (seconds).
    func offsetChanged(_ y: CGFloat, at time: Double) {
        guard isScrolling else { last = nil; return }
        defer { last = (y, time) }
        guard let last else { return }
        let dt = time - last.time
        // A gap of more than a few frames is a jump or a pause, not a speed.
        guard dt > 0, dt < 0.1 else { return }
        let speed = abs(Double(y - last.y)) / dt
        if !isFast, speed > Self.fastSpeed { isFast = true }
        if isFast, speed < Self.slowSpeed { isFast = false }
    }

    /// The scroll stopped (its phase went idle).
    func settled() {
        last = nil
        if isFast { isFast = false }
    }
}

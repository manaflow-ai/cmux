@testable import CmuxMobileFeed
import Foundation
import Testing

/// A fast scroll (a fling) shows web-rendered bodies as cheap placeholders;
/// they render once the Feed slows down or stops (verify/feed-perf-20261021.md).
@MainActor
@Suite struct FeedScrollMotionTests {
    /// Feeds offsets `step` points apart, one per 120 Hz frame.
    func scroll(_ motion: FeedScrollMotion, from start: CGFloat = 0, step: CGFloat, frames: Int, at time: inout Double) {
        var y = start
        for _ in 0..<frames {
            y += step
            time += 1.0 / 120
            motion.offsetChanged(y, at: time)
        }
    }

    func scrollingMotion() -> FeedScrollMotion {
        let motion = FeedScrollMotion()
        motion.isScrolling = true
        return motion
    }

    /// Offset changes at rest (keyboard avoidance, an inset change, a programmatic scroll) are never a fling.
    @Test func movementAtRestIsNotAFling() {
        let motion = FeedScrollMotion()
        var time = 100.0
        scroll(motion, step: 30, frames: 6, at: &time)
        #expect(!motion.isFast)
    }

    @Test func aFlingIsFastAndASlowDragIsNot() {
        let motion = scrollingMotion()
        var time = 100.0
        // 3 pt per frame at 120 Hz: 360 pt/s, a reading drag.
        scroll(motion, step: 3, frames: 20, at: &time)
        #expect(!motion.isFast)
        // 30 pt per frame: 3600 pt/s, a fling.
        scroll(motion, from: 60, step: 30, frames: 6, at: &time)
        #expect(motion.isFast)
    }

    @Test func slowingDownOrStoppingSettles() {
        let motion = scrollingMotion()
        var time = 100.0
        scroll(motion, step: 30, frames: 6, at: &time)
        #expect(motion.isFast)
        // Between the thresholds it stays fast (no flicker while a fling slows).
        scroll(motion, from: 180, step: 8, frames: 4, at: &time)
        #expect(motion.isFast)
        scroll(motion, from: 212, step: 2, frames: 4, at: &time)
        #expect(!motion.isFast)
        scroll(motion, step: 30, frames: 6, at: &time)
        #expect(motion.isFast)
        motion.settled()
        #expect(!motion.isFast)
    }

    @Test func aJumpAfterAPauseIsNotAFling() {
        let motion = scrollingMotion()
        var time = 100.0
        motion.offsetChanged(0, at: time)
        // A programmatic jump (scroll to top) after a second: no velocity from it.
        time += 1
        motion.offsetChanged(5000, at: time)
        #expect(!motion.isFast)
    }
}

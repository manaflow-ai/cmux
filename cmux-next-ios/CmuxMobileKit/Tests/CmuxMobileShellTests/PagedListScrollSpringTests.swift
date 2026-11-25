#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// The follow slide's step (``PagedListScrollSpring/step(position:velocity:goal:dt:response:)``), as plain data.
/// The slide is capped at a speed (``PagedListScrollSpring/maxSpeed``) so that no frame draws a jump,
/// whatever moves its goal: under a flood of arrivals on a `.down` list each update moved the goal by
/// 100-300 pt and the spring's next step drew it in one frame (video 8c0c85fb, 86-238 pt single-frame moves
/// between 6-34 pt steps; frame shift 0.0 because the slide is the list's own move).
struct PagedListScrollSpringTests {
    private let response = 0.35
    private let frame60 = 1.0 / 60
    private let frame120 = 1.0 / 120
    private let cap: CGFloat = 3000

    private func step(_ position: CGFloat, _ velocity: CGFloat = 0, goal: CGFloat = 0, dt: Double) -> (position: CGFloat, velocity: CGFloat, settled: Bool) {
        PagedListScrollSpring.step(position: position, velocity: velocity, goal: goal, dt: dt, response: response)
    }

    /// A normal slide step, 40 pt from its goal, moves under the cap: unchanged by it.
    @Test func aNormalStepIsUnderTheCap() {
        let next = step(40, dt: frame60)
        #expect(abs(next.position - 40) < cap * CGFloat(frame60))
        #expect(next.position < 40 && next.position > 0)
    }

    /// A slide already moving fast (6000 pt/s, the speed a slide chasing a flood reaches) meets a goal
    /// 1000 pt away: the uncapped spring draws 111 pt in one 60 Hz frame; the step is capped at the speed
    /// times the frame.
    @Test func aFastSlideIsCapped() {
        let next = step(1000, -6000, dt: frame60)
        #expect(abs(next.position - 1000) <= cap * CGFloat(frame60) + 0.01, "moved \(abs(next.position - 1000)) pt in one 60 Hz frame")
    }

    /// The cap is a speed: at 120 Hz a capped frame moves half what a capped 60 Hz frame does.
    @Test func theCapScalesWithTheFrame() {
        let at60 = abs(step(1000, -6000, dt: frame60).position - 1000)
        let at120 = abs(step(1000, -6000, dt: frame120).position - 1000)
        #expect(abs(at60 - cap * CGFloat(frame60)) < 0.5, "60 Hz frame moved \(at60) pt")
        #expect(abs(at120 - cap * CGFloat(frame120)) < 0.5, "120 Hz frame moved \(at120) pt")
    }

    /// The slide the person asked for (the newest-rows indicator) is not capped: from 6000 pt/s it
    /// moves as the spring does, more than the cap allows a frame.
    @Test func thePersonsSlideIsNotCapped() {
        let next = PagedListScrollSpring.step(position: 1000, velocity: -6000, goal: 0, dt: frame60, response: response, maxSpeed: nil)
        #expect(abs(next.position - 1000) > cap * CGFloat(frame60) + 1)
    }

    /// Arrivals faster than the cap for two seconds at 60 Hz: the goal moves away by 80 pt each frame
    /// (4800 pt/s); every step stays within the cap, the slide never jumps to catch up, and the lag grows
    /// by the same small amount each frame (smoothly), then closes once arrivals stop.
    @Test func aSustainedFloodSlidesAtTheCapAndNeverJumps() {
        var position: CGFloat = 0
        var velocity: CGFloat = 0
        var goal: CGFloat = 0
        var lags: [CGFloat] = []
        var steps: [CGFloat] = []
        for frame in 0 ..< 240 {
            if frame < 120 { goal -= 80 }
            let next = step(position, velocity, goal: goal, dt: frame60)
            steps.append(abs(next.position - position))
            position = next.position
            velocity = next.velocity
            lags.append(abs(position - goal))
        }
        #expect(steps.allSatisfy { $0 <= cap * CGFloat(frame60) + 0.01 }, "largest step \(steps.max() ?? 0) pt")
        // While arrivals outpace the cap the lag grows, by at most what they add each frame.
        let growth = zip(lags.prefix(120), lags.prefix(120).dropFirst()).map { $1 - $0 }
        #expect(growth.allSatisfy { $0 <= 80 + 0.01 })
        // Once they stop, the slide closes the lag at the cap, then settles.
        #expect(lags[239] < lags[119])
    }
}
#endif

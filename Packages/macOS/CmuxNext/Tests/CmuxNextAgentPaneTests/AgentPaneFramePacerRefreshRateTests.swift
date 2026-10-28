import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pacer's frame is the frame of the display the pane's window is on, not 120 Hz. With a fixed
/// 1/120 s, on a 60 Hz display (most external monitors, every Mac without ProMotion) a bridge call
/// that ended 10 ms after the previous one began counted as no load and the next call went at once:
/// a streaming chat made up to two bridge calls, two web-process wakes, per shown frame, and a
/// stalled link paced a sustained burst at 8.3 ms instead of the display's 16.7 ms (pro-audits item 2).
/// The pacer's contract is one call per display frame under load.
@MainActor
struct AgentPaneFramePacerRefreshRateTests {
    final class Rig {
        var clock: TimeInterval = 100
        var turns: [@MainActor @Sendable () -> Void] = []
        var calls = 0
        let ticks = AgentPaneFramePacerTests.Ticks()
        let deadline = AgentPaneHiddenPacingTests.Deadline()
        lazy var pacer = AgentPaneFramePacer(
            frames: ticks, fallback: deadline, now: { [unowned self] in self.clock },
            nextTurn: { [unowned self] work in self.turns.append(work) })

        /// A pane on a display whose frame is `frameInterval` (nil: not known).
        init(frameInterval: TimeInterval?) { ticks.frameInterval = frameInterval }

        /// Frames arrive; one call delivers them all.
        func arrive() {
            pacer.schedule { [unowned self] in
                self.calls += 1
                return AgentPaneFlush(delivered: true, more: false)
            }
        }
    }

    @Test func aSixtyHertzDisplayGetsOneCallPerFrameUnderLoad() {
        let rig = Rig(frameInterval: 1.0 / 60)
        rig.arrive()
        #expect(rig.calls == 1)
        // More frames while the call is in flight; it ends 10 ms after it began, within a 60 Hz frame.
        rig.arrive()
        rig.clock += 0.010
        rig.pacer.delivered()
        #expect(rig.calls == 1, "a call 10 ms after the previous one on a 60 Hz display: two calls in one frame")
        #expect(rig.pacer.waitingForFrame)
        #expect(rig.ticks.active)
        rig.ticks.tick()
        #expect(rig.calls == 2)
    }

    @Test func aStalledSixtyHertzLinkPacesASustainedBurstAtOneSixtiethOfASecond() throws {
        let rig = Rig(frameInterval: 1.0 / 60)
        rig.arrive()
        rig.arrive()
        rig.clock += 0.005
        rig.pacer.delivered()
        #expect(rig.pacer.waitingForFrame)
        // No display frame came: the link counts as stalled and the frames go at once.
        rig.clock += 0.020
        rig.deadline.fire()
        #expect(rig.pacer.linkStalled)
        #expect(rig.calls == 2)
        // Loaded twice in a row: the next call waits out the rest of the 60 Hz frame on the deadline.
        rig.arrive()
        rig.clock += 0.005
        rig.pacer.delivered()
        #expect(rig.pacer.waitingForInterval)
        #expect(rig.calls == 2)
        let delay = try #require(rig.deadline.delay)
        #expect(delay > .microseconds(11_600) && delay < .microseconds(11_700),
                "the stalled link's wait is \(delay), not the rest of a 60 Hz frame (11.67 ms)")
        rig.clock += 0.012
        rig.deadline.fire()
        #expect(rig.calls == 3)
    }

    /// A 120 Hz display, or one the pacer does not know, keeps its 120 Hz frames.
    @Test(arguments: [1.0 / 120, nil] as [TimeInterval?])
    func aOneTwentyHertzOrUnknownDisplayKeepsItsFrames(frameInterval: TimeInterval?) throws {
        let rig = Rig(frameInterval: frameInterval)
        rig.arrive()
        rig.arrive()
        // 10 ms is more than a 120 Hz frame: no load, the next call goes at once.
        rig.clock += 0.010
        rig.pacer.delivered()
        #expect(rig.calls == 2)
        #expect(!rig.pacer.waitingForFrame)
        // 5 ms is within one: it waits for a display frame, at most the fallback delay.
        rig.arrive()
        rig.clock += 0.005
        rig.pacer.delivered()
        #expect(rig.calls == 2)
        #expect(rig.pacer.waitingForFrame)
        #expect(rig.deadline.delay == AgentPaneFramePacer.fallbackDelay)
        rig.clock += 0.020
        rig.deadline.fire()
        #expect(rig.calls == 3)
        // Stalled and loaded twice in a row: the rest of a 120 Hz frame (3.33 ms).
        rig.arrive()
        rig.clock += 0.005
        rig.pacer.delivered()
        let delay = try #require(rig.deadline.delay)
        #expect(delay > .microseconds(3_300) && delay < .microseconds(3_350))
    }

    /// The wait for a display frame is longer than one frame of a slow display: on a 30 Hz display a
    /// frame that comes on time does not count as a stalled link.
    @Test func aThirtyHertzDisplayWaitsMoreThanOneFrameBeforeTheLinkCountsAsStalled() {
        let rig = Rig(frameInterval: 1.0 / 30)
        rig.arrive()
        rig.arrive()
        rig.clock += 0.010
        rig.pacer.delivered()
        #expect(rig.calls == 1)
        #expect(rig.pacer.waitingForFrame)
        #expect(rig.deadline.delay == .milliseconds(40), "a 30 Hz frame is 33 ms: a 20 ms wait calls every on-time frame missed")
    }
}

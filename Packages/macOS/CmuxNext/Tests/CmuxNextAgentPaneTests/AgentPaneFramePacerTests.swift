import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor final class PacerFakeFrames: AgentPaneFrameTicks {
    var onTick: (@MainActor () -> Void)?
    private(set) var active = false
    func activate() { active = true }
    func deactivate() { active = false }
    /// A display frame: the window's client fires once, then goes idle.
    func tick() {
        guard active else { return }
        active = false
        onTick?()
    }
}

@MainActor final class PacerFakeDeadline: AgentPaneFallbackDeadline {
    private var action: (@MainActor @Sendable () -> Void)?
    var isScheduled: Bool { action != nil }
    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
    func cancel() { action = nil }
    func fire() { let action = self.action; self.action = nil; action?() }
}

/// The pacer delivers at once with no load, coalesces only while a call is in flight, makes at
/// most one call per display frame under load, and never waits on a display link that does not
/// fire (an occluded or hidden window falls back to next-turn delivery).
@MainActor
@Suite struct AgentPaneFramePacerTests {
    final class Rig {
        var clock: TimeInterval = 1000
        let frames = PacerFakeFrames()
        let deadline = PacerFakeDeadline()
        var turns: [@MainActor @Sendable () -> Void] = []
        var flushes = 0
        var more = false
        var delivers = true
        lazy var pacer = AgentPaneFramePacer(frames: frames, fallback: deadline, now: { [unowned self] in self.clock },
                                             nextTurn: { [unowned self] work in self.turns.append(work) })
        lazy var flush: @MainActor @Sendable () -> AgentPaneFlush = { [unowned self] in
            self.flushes += 1
            return AgentPaneFlush(delivered: self.delivers, more: self.more)
        }
        func arrive() { pacer.schedule(flush) }
        func runTurns() { let pending = turns; turns = []; pending.forEach { $0() } }
    }

    @Test func noLoadMeansImmediateDelivery() {
        let rig = Rig()
        rig.arrive()
        #expect(rig.flushes == 1, "delivered on the arrival turn")
        #expect(!rig.frames.active && rig.turns.isEmpty && !rig.deadline.isScheduled)
        // Idle again a while later: immediate again.
        rig.pacer.delivered()
        rig.clock += 1
        rig.arrive()
        #expect(rig.flushes == 2)
    }

    @Test func framesWhileACallIsInFlightGoTogether() {
        let rig = Rig()
        rig.arrive()
        rig.arrive()
        rig.arrive()
        rig.arrive()
        #expect(rig.flushes == 1, "coalesced while the first call is in flight")
        rig.clock += AgentPaneFramePacer.frameInterval
        rig.pacer.delivered()
        #expect(rig.flushes == 2, "one call for the three that waited")
        rig.clock += AgentPaneFramePacer.frameInterval
        rig.pacer.delivered()
        #expect(rig.flushes == 2, "nothing left: no call")
    }

    @Test func underLoadAtMostOneCallPerFrame() {
        let rig = Rig()
        rig.arrive()
        var ticks = 0
        for _ in 0..<200 {
            // The page runs each call in 1 ms, and frames keep arriving.
            rig.clock += 0.001
            rig.arrive()
            rig.pacer.delivered()
            if rig.frames.active {
                ticks += 1
                rig.clock += AgentPaneFramePacer.frameInterval
                rig.frames.tick()
            }
        }
        #expect(ticks > 0)
        #expect(rig.flushes <= ticks + 1, "\(rig.flushes) calls for \(ticks) frames")
        #expect(rig.turns.isEmpty)
    }

    @Test func aDisplayLinkThatDoesNotFireFallsBackToNextTurnDelivery() {
        let rig = Rig()
        rig.arrive()
        rig.clock += 0.001
        rig.arrive()
        rig.pacer.delivered()
        #expect(rig.pacer.waitingForFrame && rig.deadline.isScheduled)
        // The window is occluded: no frame comes; the fallback deadline fires.
        rig.deadline.fire()
        #expect(rig.flushes == 2, "delivered without a frame")
        #expect(rig.pacer.linkStalled)
        // While the link is stalled, every call goes on the next turn: no 10 Hz.
        for _ in 0..<50 {
            rig.clock += 0.001
            rig.arrive()
            rig.pacer.delivered()
            #expect(!rig.pacer.waitingForFrame)
            rig.runTurns()
        }
        #expect(rig.flushes == 52)
        // A real frame again: back to frame pacing.
        rig.frames.activate()
        rig.frames.tick()
        #expect(!rig.pacer.linkStalled)
    }

    @Test func aCappedFlushContinuesAndAnEmptyOneDoesNotBlock() {
        let rig = Rig()
        rig.more = true
        rig.arrive()
        rig.more = false
        rig.clock += AgentPaneFramePacer.frameInterval
        rig.pacer.delivered()
        #expect(rig.flushes == 2, "the rest of a capped flush went after the call")
        // A flush that made no call leaves nothing in flight.
        rig.pacer.delivered()
        rig.delivers = false
        rig.clock += 1
        rig.arrive()
        rig.delivers = true
        rig.arrive()
        #expect(rig.flushes == 4)
    }
}

import Foundation
import Testing
@testable import CmuxMobileTerminal

/// r13 D1: bytes the Mac wrote as one update (a row, then the live area
/// redrawn under it) reach Ghostty in one batch, so no frame shows the row
/// without its live area (verifier 2026-10-19: 46 torn frames in 66 s).
@Suite struct TerminalOutputBurstTests {
    /// Replays arrivals through the controller's pump rules: a feed starts
    /// when the pacer allows (at arrival, at a display frame every 1/60 s,
    /// or at the pacer's wake time) and Ghostty finishes it 0.2 ms later.
    /// Returns the batches handed to Ghostty.
    static func run(_ arrivals: [(TimeInterval, String)], pacer start: TerminalFeedPacer = TerminalFeedPacer(),
                    until end: TimeInterval = 0.2) -> [String] {
        var pacer = start
        var queue = TerminalOutputQueue()
        var batches: [String] = []
        var finishAt: TimeInterval?
        let frame = 1.0 / 60
        var events = arrivals.map { ($0.0, Optional($0.1)) }
        var tick = 0.0
        while tick <= end { events.append((tick, nil)); tick += frame }
        events.sort { $0.0 < $1.0 }
        var index = 0
        var now = 0.0
        func pump(_ now: TimeInterval) {
            if let done = finishAt, now >= done { pacer.finished(); finishAt = nil }
            guard pacer.canFeed(at: now), case .bytes(let data)? = queue.next() else { return }
            batches.append(String(decoding: data, as: UTF8.self))
            pacer.started(frameEnd: (floor(now / frame) + 1) * frame, queueEmpty: queue.isEmpty)
            finishAt = now + 0.0002
        }
        while index < events.count || pacer.wakeTime(at: now) != nil || finishAt != nil {
            var next = index < events.count ? events[index].0 : .infinity
            if let wake = pacer.wakeTime(at: now) { next = min(next, wake) }
            if let done = finishAt { next = min(next, done) }
            guard next.isFinite else { break }
            now = next
            if index < events.count, events[index].0 <= now {
                let (_, chunk) = events[index]
                index += 1
                if let chunk {
                    queue.append(Data(chunk.utf8))
                    pacer.arrived(at: now)
                } else {
                    pacer.newFrame()
                }
            }
            pump(now)
        }
        return batches
    }

    @Test func aRowAndItsLiveAreaGoInOneBatch() {
        // stream20: the row, then 0.4 ms later the live area under it; 20 rows/s.
        var arrivals: [(TimeInterval, String)] = []
        for n in 0..<4 {
            let t = 0.003 + Double(n) * 0.05
            arrivals.append((t, "row\(n)|"))
            arrivals.append((t + 0.0004, "live\(n)|"))
        }
        let batches = Self.run(arrivals, until: 0.25)
        #expect(batches == ["row0|live0|", "row1|live1|", "row2|live2|", "row3|live3|"])
    }

    @Test func aSingleEchoWaitsOnlyTheQuietGap() {
        var pacer = TerminalFeedPacer()
        pacer.arrived(at: 1.0)
        #expect(!pacer.canFeed(at: 1.0))
        #expect(pacer.wakeTime(at: 1.0) == 1.0 + TerminalOutputBurst.quiet)
        #expect(pacer.canFeed(at: 1.0 + TerminalOutputBurst.quiet))
    }

    @Test func aSteadyFloodStillFeedsWithinTheMaximumHold() {
        var pacer = TerminalFeedPacer()
        var t = 1.0
        pacer.arrived(at: t)
        while t < 1.0 + TerminalOutputBurst.maxHold - 0.002 {
            t += 0.001
            pacer.arrived(at: t)
            #expect(!pacer.canFeed(at: t))
        }
        #expect(pacer.canFeed(at: 1.0 + TerminalOutputBurst.maxHold))
    }

    @Test func aBacklogOverTheBudgetGoesNextFrameWithoutANewWait() {
        var pacer = TerminalFeedPacer()
        pacer.arrived(at: 1.0)
        pacer.started(frameEnd: 1.016, queueEmpty: false)
        pacer.finished()
        pacer.newFrame()
        #expect(pacer.canFeed(at: 1.017))
    }

    @Test func withTheHoldOffTheFirstChunkGoesAlone() {
        let arrivals: [(TimeInterval, String)] = [(0.003, "row|"), (0.0034, "live|")]
        #expect(Self.run(arrivals, pacer: TerminalFeedPacer(holdsBursts: false)) == ["row|", "live|"])
    }
}

/// r13 review: after a drain that ended on an alternate screen switch, the
/// next chunk still waits for its burst.
@Suite struct TerminalFeedPacerDrainTests {
    @Test func aDrainedQueueStartsANewBurst() {
        var pacer = TerminalFeedPacer()
        pacer.arrived(at: 1.0)
        pacer.started(frameEnd: 1.016, queueEmpty: false)  // an alternate screen step was left
        pacer.finished()
        pacer.drained()
        pacer.newFrame()
        pacer.arrived(at: 5.0)
        #expect(!pacer.canFeed(at: 5.0))
        #expect(pacer.canFeed(at: 5.0 + TerminalOutputBurst.quiet))
    }
}

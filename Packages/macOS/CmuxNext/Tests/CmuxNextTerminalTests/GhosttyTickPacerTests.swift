@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Ghostty's wakeup ticks paced to the frame (p03-rendering-119): a stream of wakeups ticks at most once
/// per frame with no hop per wakeup, a quiet spell's first wakeup and a key's echo tick at once, and
/// `GhosttyRuntime.tick` shows in debug.wakeups.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct GhosttyTickPacerTests {
    @Test func tenThousandWakeupsASecondTickAtMostOncePerFrame() {
        let rig = PacerRig()
        for _ in 0..<120 {
            // 1/120 s of wakeups 100 us apart, each hop reaching main at once (the worst case).
            for _ in 0..<83 {
                rig.clock.now += 100_000
                rig.wake()
                rig.deliverHops()
            }
            let before = rig.ticks
            rig.frame()
            #expect(rig.ticks - before <= 1)
        }

        #expect(rig.ticks == 121, "the burst's first tick ran at once, then one per frame")
        #expect(rig.ticksOutsideFrames == 1)
        #expect(rig.hops == 2, "the first wakeup ticked; the second started the pacing; the rest made no hop")
        #expect(rig.ledgerCount(reason: "frame") == 120)
        #expect(rig.ledgerCount(reason: "wakeup") == 2)
    }

    @Test func aQuietSpellsFirstWakeupTicksAtOnce() {
        let rig = PacerRig()
        rig.wake()
        rig.deliverHops()

        #expect(rig.ticks == 1)
        #expect(!rig.pacer.isPacing)
        #expect(rig.scheduler.activeClients.isEmpty, "a lone wakeup keeps no frame client")
    }

    @Test func theClientStopsAfterTwoEmptyFramesAndTheNextWakeupHopsAgain() {
        let rig = PacerRig()
        rig.stream()
        #expect(rig.pacer.isPacing)
        rig.frame()
        rig.frame()
        #expect(rig.scheduler.activeClients == [GhosttyTickPacer.owner], "one empty frame keeps the client")
        rig.frame()
        #expect(rig.scheduler.activeClients.isEmpty)
        #expect(!rig.pacer.isPacing)
        #expect(!rig.context.framed.load(ordering: .relaxed))

        rig.clock.now += 1_000_000_000
        let (ticks, hops) = (rig.ticks, rig.hops)
        rig.wake()
        rig.deliverHops()
        #expect(rig.hops == hops + 1)
        #expect(rig.ticks == ticks + 1, "a wakeup after the stream ended ticks in its hop's turn")
    }

    @Test func aKeysEchoNeverWaitsForAFrame() {
        let rig = PacerRig()
        rig.stream()
        rig.frame()
        rig.pacer.noteTerminalKey()
        rig.isInputTick = true
        let ticks = rig.ticks

        rig.clock.now += 1_000_000
        rig.wake()
        rig.deliverHops()

        #expect(rig.ticks == ticks + 1, "the echo ticks in its hop's turn, mid-stream")
        #expect(!rig.pacer.isPacing)
    }

    @Test func aWakeupLeftToTheFrameBeforeAKeyTicksOnTheNextFrame() {
        let rig = PacerRig()
        rig.stream()
        rig.frame()
        rig.clock.now += 1_000_000
        rig.wake()
        #expect(rig.hops == 2, "the client is on: the wakeup made no hop")
        rig.pacer.noteTerminalKey()
        let ticks = rig.ticks

        rig.frame()

        #expect(rig.ticks == ticks + 1)
        #expect(rig.scheduler.activeClients.isEmpty, "the key stopped the pacing; the frame ran what was left")
    }

    @Test func aHopAFrameBeatRunsNoSecondTick() {
        let rig = PacerRig()
        rig.stream()
        rig.frame()
        rig.pacer.noteTerminalKey()
        rig.clock.now += 1_000_000
        rig.wake()
        #expect(rig.queuedHops == 1)
        rig.frame()
        let ticks = rig.ticks

        rig.deliverHops()

        #expect(rig.ticks == ticks)
    }

    @Test func theRuntimeTicksAtOnceBeforeAttachAndPacesAfter() {
        let runtime = GhosttyRuntime()
        runtime.context.pending.store(true, ordering: .relaxed)
        runtime.wakeupArrived(posted: MainTaskPost())
        #expect(!runtime.context.pending.load(ordering: .relaxed), "before attach, a hop runs the tick")
        #expect(runtime.tickPacer == nil)

        let work = MainWorkScheduler.testing(performTurn: { _ in }) { _ in PacerTestLink() }
        runtime.attach(to: work)
        #expect(runtime.tickPacer != nil)
    }
}

/// A pacer on a fake frame scheduler, clock and ledger, whose tick counts and clears the pending flag
/// as the runtime's does.
@MainActor
private final class PacerRig {
    final class MovingClock {
        var now: UInt64 = 1_000_000_000
    }

    let clock = MovingClock()
    let ledger = WakeupLedger(uptime: { 0 })
    let context = RuntimeCallbackContext()
    let scheduler: FrameScheduler
    var isInputTick = false
    private(set) var ticks = 0
    private(set) var ticksOutsideFrames = 0
    private(set) var hops = 0
    private(set) var queuedHops = 0
    private(set) var pacer: GhosttyTickPacer!
    private var frames = 0
    private var inFrame = false

    init() {
        scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in PacerTestLink() }
        let clock = clock
        pacer = GhosttyTickPacer(context: context, frames: scheduler, ledger: ledger, now: { clock.now },
                                 isInputTick: { [weak self] in self?.isInputTick ?? false },
                                 tick: { [weak self] _ in self?.recordTick() })
    }

    /// A wakeup from Ghostty's thread: queues a hop when the context asks for one.
    func wake() {
        if context.wake() { queuedHops += 1 }
    }

    /// The queued hops reach main.
    func deliverHops() {
        while queuedHops > 0 {
            queuedHops -= 1
            hops += 1
            pacer.wakeupArrived(posted: nil)
        }
    }

    /// Two wakeups 100 us apart: the second starts the pacing.
    func stream() {
        for _ in 0..<2 {
            clock.now += 100_000
            wake()
            deliverHops()
        }
    }

    /// One 120 Hz link frame.
    func frame() {
        frames += 1
        inFrame = true
        scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        inFrame = false
    }

    func ledgerCount(reason: String) -> UInt64 {
        ledger.snapshot().first { $0.owner == GhosttyTickPacer.owner && $0.reason == reason }?.count ?? 0
    }

    private func recordTick() {
        context.pending.store(false, ordering: .releasing)
        ticks += 1
        if !inFrame { ticksOutsideFrames += 1 }
    }
}

@MainActor
private final class PacerTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

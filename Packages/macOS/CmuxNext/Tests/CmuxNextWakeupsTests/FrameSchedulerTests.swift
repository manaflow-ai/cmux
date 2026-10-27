import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreFoundation
import QuartzCore
import Testing

/// frame.tick, frame.commit and frame.present_estimate (p09-observability 037) on fake display links:
/// each link tick writes frame.tick with its display while the frame category records, each run-loop turn's
/// commit writes one frame.commit, and a key flow's commit is presented at the first vsync of its own display
/// whose target is at or after max(its commit, its GPU completion), as Chrome dates a presentation it did not
/// get from the display (ui/gfx/presentation_feedback.h, no `kHWClock`).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerTests {
    private static let interval = 1.0 / 60

    /// Off: a link tick and a commit write nothing, and a marked flow asks for no link.
    @Test func offWritesNothingAndAsksForNoLink() {
        let rig = PresentRig(recording: false)
        rig.presents.markCommit(flow: 7, display: 2)
        rig.presents.turnDidCommit()
        #expect(!rig.displays.hasLink(2) && rig.links.made == 0, "the presents asked for a link while not recording")
        let spring = rig.spring()
        rig.displays.displayDidFire(1, timestamp: 1, refreshInterval: Self.interval, targetTimestamp: 1 + Self.interval)
        #expect(rig.log.records.isEmpty, "\(rig.log.records.count) records while the frame category is off")
        #expect(rig.presents.waitingFlows.isEmpty)
        spring.deactivate()
    }

    /// Recording, each link tick writes frame.tick: its timestamp, its display and the time to its target.
    @Test func eachLinkTickWritesFrameTickWithItsDisplay() throws {
        let rig = PresentRig()
        let spring = rig.spring()
        rig.displays.displayDidFire(1, timestamp: 2, refreshInterval: Self.interval, targetTimestamp: 2.016)
        let tick = try #require(rig.log.records(.frameTick).first)
        #expect(rig.log.records(.frameTick).count == 1)
        #expect(tick.arg0 == 2_000_000_000)
        #expect(tick.arg1 >> 32 == 1, "the tick does not name its display")
        #expect(tick.arg1 & 0xFFFF_FFFF == 16_000_000)
        #expect(tick.flags.isEmpty)
        spring.deactivate()
    }

    /// Commit then tick: the idle display gets one tick for the flow, its vsync presents the flow with the
    /// estimated flag, and the link it made goes with that tick.
    @Test func aCommitIsPresentedAtTheFirstVsyncAfterIt() throws {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7, display: 1)
        #expect(!rig.displays.hasLink(1), "the link ran before the commit")
        rig.now.now = 1_000_000_000
        rig.presents.turnDidCommit()
        let commit = try #require(rig.log.records(.frameCommit).first)
        #expect(commit.arg0 == 7 && commit.arg1 == 1)
        #expect(rig.displays.hasLink(1) && rig.links.made == 1, "an idle display was not asked for one tick")
        rig.displays.displayDidFire(1, timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg0 == 7)
        #expect(present.arg1 == 1_020_000_000)
        #expect(present.flags == .estimated)
        #expect(rig.presents.waitingFlows.isEmpty)
        #expect(!rig.displays.hasLink(1) && rig.links.made == 1, "the one tick's link kept running")
    }

    /// Two displays: a flow on the second is presented by its vsync, not by the first display's, and only
    /// the second display is asked for a tick.
    @Test func onlyTheFlowsDisplayPresentsIt() throws {
        let rig = PresentRig()
        let spring = rig.spring()
        rig.presents.markCommit(flow: 7, display: 2)
        rig.now.now = 1_000_000_000
        rig.presents.turnDidCommit()
        #expect(rig.displays.hasLink(2), "the flow's display was not asked for a tick")
        rig.displays.displayDidFire(1, timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        #expect(rig.log.records(.framePresentEstimate).isEmpty, "another display's vsync presented the flow")
        rig.displays.displayDidFire(2, timestamp: 1.008, refreshInterval: 1.0 / 120, targetTimestamp: 1.0163)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg1 == 1_016_300_000)
        #expect(rig.log.records(.frameTick).map { $0.arg1 >> 32 } == [1, 2])
        spring.deactivate()
    }

    /// A vsync whose target is before the commit does not present it; the next one does.
    @Test func aVsyncBeforeTheCommitDoesNotPresentIt() throws {
        let rig = PresentRig()
        let spring = rig.spring()
        rig.presents.markCommit(flow: 7, display: 1)
        rig.now.now = 1_030_000_000
        rig.presents.turnDidCommit()
        rig.displays.displayDidFire(1, timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        #expect(rig.log.records(.framePresentEstimate).isEmpty, "presented at a vsync before its commit")
        rig.displays.displayDidFire(1, timestamp: 1.020, refreshInterval: Self.interval, targetTimestamp: 1.037)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg1 == 1_037_000_000)
        spring.deactivate()
    }

    /// A GPU that finishes before the vsync leaves the present at that vsync; one that finishes after
    /// it moves the present one frame later.
    @Test func gpuDoneAfterTheVsyncMovesThePresentOneFrameLater() throws {
        let early = try presentTarget(gpuDoneNanos: 1_010_000_000)
        let late = try presentTarget(gpuDoneNanos: 1_025_000_000)
        #expect(early == 1_020_000_000)
        #expect(late == 1_037_000_000, "a GPU done after the vsync did not move the present one frame")
    }

    /// A flow that waits for its GPU asks for no tick; its GPU completion asks for one.
    @Test func aGPUCompletionAsksForTheTick() throws {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7, display: 1, awaitsGPU: true)
        rig.now.now = 1_000_000_000
        rig.presents.turnDidCommit()
        #expect(!rig.displays.hasLink(1), "a flow still waiting for its GPU asked for a tick")
        rig.presents.gpuDidFinish(flow: 7, atNanos: 1_004_000_000)
        #expect(rig.displays.hasLink(1), "the GPU completion asked for no tick")
        rig.displays.displayDidFire(1, timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg1 == 1_020_000_000)
    }

    /// A flow whose GPU work never reports is dropped after its display's ticks, however they come.
    @Test func aFlowThatNeverPresentsIsDroppedAfterItsFrames() {
        let rig = PresentRig()
        let spring = rig.spring()
        rig.presents.markCommit(flow: 7, display: 1, awaitsGPU: true)
        rig.now.now = 1_000_000_000
        rig.presents.turnDidCommit()
        for frame in 0...FramePresentEstimate.framesToWait {
            let start = 1.005 + Double(frame) * Self.interval
            rig.displays.displayDidFire(1, timestamp: start, refreshInterval: Self.interval, targetTimestamp: start + Self.interval)
        }
        #expect(rig.presents.waitingFlows.isEmpty)
        #expect(rig.log.records(.framePresentEstimate).isEmpty)
        spring.deactivate()
    }

    /// The typing probe hands a press's echo commit to the presents: the press's flow, on the display of the
    /// terminal it went to, is presented by that display's next vsync.
    @Test func aTypingProbeEchoIsPresentedOnItsDisplay() throws {
        let rig = PresentRig()
        let probe = TypingLatencyProbe(path: nil, trace: rig.trace)
        rig.presents.pendingCommits = { probe.takePresentCommits() }
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(surface, display: 2)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: surface)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        probe.mark(.contents, surface: surface)
        rig.now.now = 1_000_000_000
        probe.turnDidEnd()
        rig.presents.turnDidCommit()
        probe.stopFlows()
        let commit = try #require(rig.log.records(.frameCommit).first)
        #expect(commit.arg0 == flow)
        rig.displays.displayDidFire(2, timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg0 == flow)
        #expect(present.arg1 == 1_020_000_000)
    }

    /// The run-loop observer writes one frame.commit for the turn's commit, with the flow it carries,
    /// however many commit boundaries wait on that commit.
    @Test func oneFrameCommitForEachTurn() throws {
        let log = FrameRecordLog()
        let trace = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        trace.setCategoryMask(TraceCategories.frame.rawValue)
        let presents = FramePresentEstimate(trace: trace)
        presents.observeCommits()
        presents.markCommit(flow: 9, display: 1)
        let box = OutcomeBox()
        CommitBoundary().after { box.outcomes.append($0) }
        CommitBoundary().after { box.outcomes.append($0) }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        CFRunLoopTimerInvalidate(timer)
        #expect(box.outcomes == [.committed, .committed])
        let commits = log.records(.frameCommit)
        #expect(commits.count == 1, "\(commits.count) frame.commit records for one turn's commit")
        let commit = try #require(commits.first)
        #expect(commit.arg0 == 9)
        #expect(commit.arg1 == 1)
    }

    /// The vsync target, in trace nanoseconds, that presents a flow committed at 1.000 s whose GPU work
    /// finishes at `gpuDoneNanos`, learned on main after the 1.020 s vsync's tick.
    private func presentTarget(gpuDoneNanos: UInt64) throws -> UInt64 {
        let rig = PresentRig()
        let spring = rig.spring()
        defer { spring.deactivate() }
        rig.presents.markCommit(flow: 7, display: 1, awaitsGPU: true)
        rig.now.now = 1_000_000_000
        rig.presents.turnDidCommit()
        rig.displays.displayDidFire(1, timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        #expect(rig.log.records(.framePresentEstimate).isEmpty, "presented before its GPU work finished")
        rig.presents.gpuDidFinish(flow: 7, atNanos: gpuDoneNanos)
        if rig.log.records(.framePresentEstimate).isEmpty {
            rig.displays.displayDidFire(1, timestamp: 1.020, refreshInterval: Self.interval, targetTimestamp: 1.037)
        }
        return try #require(rig.log.records(.framePresentEstimate).first).arg1
    }
}

/// A display clock on fake links (every window-less scheduler on display 1) whose presents write to a
/// runtime of their own and whose commits the test ends by hand.
@MainActor
private final class PresentRig {
    let log: FrameRecordLog
    let links: PresentLinks
    /// The trace clock's uptime nanoseconds.
    let now: FakeUptime
    let trace: TraceRuntime
    let presents: FramePresentEstimate
    let displays: DisplayClock

    init(recording: Bool = true) {
        let log = FrameRecordLog(), now = FakeUptime(), links = PresentLinks()
        self.log = log
        self.now = now
        self.links = links
        let clock = TraceClock(reader: .init(uptimeNanos: { now.now }, continuousNow: { ContinuousClock.now }))
        let trace = TraceRuntime(role: .app, clock: clock, stubRecorder: { log.append($0) })
        trace.setCategoryMask(recording ? TraceCategories.frame.rawValue : 0)
        let presents = FramePresentEstimate(trace: trace, clock: clock, observesRunLoop: false)
        self.trace = trace
        self.presents = presents
        displays = DisplayClock(makeLink: { _, _ in links.make() }, displayOf: { _ in 1 }, clock: ManualClock(),
                                mediaTime: { 1 }, presents: presents)
    }

    /// A spring that keeps display 1's link running, as a busy app does.
    func spring() -> FrameClient {
        let scheduler = FrameScheduler(name: "spring", host: .screen, displays: displays, clock: ManualClock(), budget: nil)
        let client = FrameClient(owner: "spring", on: scheduler) { _ in true }
        client.activate()
        return client
    }
}

/// The outcomes the boundaries reported.
@MainActor
private final class OutcomeBox {
    var outcomes: [CommitBoundary.Outcome] = []
}

/// The records a test runtime wrote.
private nonisolated final class FrameRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    func records(_ name: SignpostName) -> [TraceRuntime.StubRecord] {
        records.filter { $0.name == name.rawValue }
    }
}

@MainActor
private final class PresentLinks {
    private(set) var made = 0

    func make() -> PresentLink {
        made += 1
        return PresentLink()
    }
}

@MainActor
private final class PresentLink: FrameLink {
    var isPaused = false

    func invalidate() {}
}

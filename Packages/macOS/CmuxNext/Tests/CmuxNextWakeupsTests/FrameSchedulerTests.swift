import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreFoundation
import QuartzCore
import Testing

/// frame.tick, frame.commit and frame.present_estimate (p09-observability 037) on a fake link: each link
/// tick writes frame.tick while the frame category records, and a key flow's commit is presented at the
/// first vsync whose target is at or after max(its commit, its GPU completion), as Chrome dates a
/// presentation it did not get from the display (ui/gfx/presentation_feedback.h, no `kHWClock`).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerTests {
    private static let interval = 1.0 / 60

    /// Off: no record, no commit boundary, no link for the presents.
    @Test func offWritesNothingAndAsksForNoFrame() {
        let rig = PresentRig(recording: false)
        let client = FrameClient(owner: "spring", on: rig.scheduler) { _ in true }
        client.activate()
        rig.presents.markCommit(flow: 7)
        #expect(rig.pendingCommits.isEmpty, "a commit boundary was installed while not recording")
        rig.scheduler.frameDidFire(timestamp: 1, refreshInterval: Self.interval, targetTimestamp: 1 + Self.interval)
        #expect(rig.log.records.isEmpty, "\(rig.log.records.count) records while the frame category is off")
        #expect(rig.presents.waitingFlows.isEmpty)
        client.deactivate()
        #expect(rig.links.made == 1, "the presents asked for a link while not recording")
    }

    /// Recording, each link tick writes frame.tick with its timestamp and target.
    @Test func eachLinkTickWritesFrameTick() {
        let rig = PresentRig()
        let client = FrameClient(owner: "spring", on: rig.scheduler) { _ in true }
        client.activate()
        rig.scheduler.frameDidFire(timestamp: 2, refreshInterval: Self.interval, targetTimestamp: 2.016)
        let ticks = rig.log.records(.frameTick)
        #expect(ticks.count == 1)
        #expect(ticks.first?.arg0 == 2_000_000_000)
        #expect(ticks.first?.arg1 == 2_016_000_000)
        #expect(ticks.first?.flags.isEmpty == true)
        client.deactivate()
    }

    /// Commit then tick: the idle link runs for the flow, the first vsync at or after the commit
    /// presents it with the estimated flag, and the link stops again.
    @Test func aCommitIsPresentedAtTheFirstVsyncAfterIt() throws {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7)
        #expect(rig.pendingCommits.count == 1)
        #expect(!rig.scheduler.hasLink, "the link ran before the commit ended")
        rig.now.set(1_000_000_000)
        rig.endCommit()
        #expect(rig.scheduler.hasLink && rig.links.made == 1, "an idle link was not asked for one tick")
        rig.scheduler.frameDidFire(timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg0 == 7)
        #expect(present.arg1 == 1_020_000_000)
        #expect(present.flags == .estimated)
        #expect(rig.presents.waitingFlows.isEmpty)
        #expect(!rig.scheduler.hasLink, "the link kept running after the present")
    }

    /// A vsync whose target is before the commit does not present it; the next one does.
    @Test func aVsyncBeforeTheCommitDoesNotPresentIt() throws {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7)
        rig.now.set(1_030_000_000)
        rig.endCommit()
        rig.scheduler.frameDidFire(timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        #expect(rig.log.records(.framePresentEstimate).isEmpty, "presented at a vsync before its commit")
        rig.scheduler.frameDidFire(timestamp: 1.020, refreshInterval: Self.interval, targetTimestamp: 1.037)
        let present = try #require(rig.log.records(.framePresentEstimate).first)
        #expect(present.arg1 == 1_037_000_000)
    }

    /// A GPU that finishes before the vsync leaves the present at that vsync; one that finishes after
    /// it moves the present one frame later.
    @Test func gpuDoneAfterTheVsyncMovesThePresentOneFrameLater() throws {
        let early = try presentTarget(gpuDoneNanos: 1_010_000_000)
        let late = try presentTarget(gpuDoneNanos: 1_025_000_000)
        #expect(early == 1_020_000_000)
        #expect(late == 1_037_000_000, "a GPU done after the vsync did not move the present one frame")
    }

    /// A flow whose GPU work never reports is dropped after its frames and stops the link.
    @Test func aFlowThatNeverPresentsIsDroppedAndTheLinkStops() {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7, awaitsGPU: true)
        rig.now.set(1_000_000_000)
        rig.endCommit()
        for frame in 0...FramePresentEstimate.framesToWait {
            let start = 1.005 + Double(frame) * Self.interval
            rig.scheduler.frameDidFire(timestamp: start, refreshInterval: Self.interval, targetTimestamp: start + Self.interval)
        }
        #expect(rig.presents.waitingFlows.isEmpty)
        #expect(rig.log.records(.framePresentEstimate).isEmpty)
        #expect(!rig.scheduler.hasLink, "the link kept running for a flow that was dropped")
    }

    /// A missed boundary (the run loop slept first) measured no commit: the flow is not presented.
    @Test func aMissedBoundaryHasNoPresent() {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7)
        rig.endCommit(.missed)
        #expect(rig.presents.waitingFlows.isEmpty)
        #expect(!rig.scheduler.hasLink)
    }

    /// The real boundary writes frame.commit with its flow after the turn's commit.
    @Test func theCommitBoundaryWritesFrameCommit() {
        let log = FrameRecordLog()
        let trace = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        trace.setCategoryMask(TraceCategories.frame.rawValue)
        let box = OutcomeBox()
        CommitBoundary(trace: trace).after(flow: 9) { box.outcome = $0 }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        CFRunLoopTimerInvalidate(timer)
        #expect(box.outcome == .committed)
        #expect(log.records(.frameCommit).map(\.arg0) == [9])
    }

    /// The vsync target, in trace nanoseconds, that presents a flow committed at 1.000 s whose GPU work
    /// finishes at `gpuDoneNanos`, learned on main after the 1.020 s vsync's tick.
    private func presentTarget(gpuDoneNanos: UInt64) throws -> UInt64 {
        let rig = PresentRig()
        rig.presents.markCommit(flow: 7, awaitsGPU: true)
        rig.now.set(1_000_000_000)
        rig.endCommit()
        rig.scheduler.frameDidFire(timestamp: 1.005, refreshInterval: Self.interval, targetTimestamp: 1.020)
        #expect(rig.log.records(.framePresentEstimate).isEmpty, "presented before its GPU work finished")
        rig.presents.gpuDidFinish(flow: 7, atNanos: gpuDoneNanos)
        if rig.log.records(.framePresentEstimate).isEmpty {
            rig.scheduler.frameDidFire(timestamp: 1.020, refreshInterval: Self.interval, targetTimestamp: 1.037)
        }
        return try #require(rig.log.records(.framePresentEstimate).first).arg1
    }
}

/// A test scheduler on a fake link whose clock's presents write to a runtime of their own, with the commit
/// boundaries held until the test ends them.
@MainActor
private final class PresentRig {
    let log: FrameRecordLog
    let links: PresentLinks
    /// The trace clock's uptime nanoseconds.
    let now: FakeUptime
    let presents: FramePresentEstimate
    let scheduler: FrameScheduler
    private let commits: PendingCommits

    /// The commit boundaries not ended yet.
    var pendingCommits: [@MainActor (CommitBoundary.Outcome) -> Void] { commits.bodies }

    init(recording: Bool = true) {
        let log = FrameRecordLog(), now = FakeUptime(), commits = PendingCommits(), links = PresentLinks()
        let clock = TraceClock(reader: .init(uptimeNanos: { now.value }, continuousNow: { ContinuousClock.now }))
        let trace = TraceRuntime(role: .app, clock: clock, stubRecorder: { log.append($0) })
        trace.setCategoryMask(recording ? TraceCategories.frame.rawValue : 0)
        let presents = FramePresentEstimate(trace: trace, clock: clock) { _, body in commits.bodies.append(body) }
        self.log = log
        self.now = now
        self.commits = commits
        self.links = links
        self.presents = presents
        scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { 1 }, presents: presents) { _ in links.make() }
    }

    /// Ends the oldest pending commit with `outcome`.
    func endCommit(_ outcome: CommitBoundary.Outcome = .committed) {
        guard !commits.bodies.isEmpty else { return }
        commits.bodies.removeFirst()(outcome)
    }
}

@MainActor
private final class PendingCommits {
    var bodies: [@MainActor (CommitBoundary.Outcome) -> Void] = []
}

/// The uptime a test's trace clock reads.
private nonisolated final class FakeUptime: Sendable {
    private let state = Mutex<UInt64>(0)

    var value: UInt64 { state.withLock { $0 } }

    func set(_ nanos: UInt64) { state.withLock { $0 = nanos } }
}

/// The outcome a boundary reported.
@MainActor
private final class OutcomeBox {
    var outcome: CommitBoundary.Outcome?
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

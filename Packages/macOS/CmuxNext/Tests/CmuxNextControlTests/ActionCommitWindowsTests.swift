import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import QuartzCore
import Testing

/// `action.missed_frames.cmd_t/n/w` (p09-observability task 056): a committed key or pointer run opens a commit
/// window on the scheduler the person acts in, and the window a New Tab, New Window or Close Tab key run opened (or
/// last extended) records its dropped refreshes when it closes. Driven through the monitor's commit hook and the
/// schedulers' frame sequences (task 057), on synthetic 60 Hz link ticks.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ActionCommitWindowsTests {
    /// Cmd-T's window drops one refresh: one sample of 1, for Cmd-T only.
    @Test func aCommandsWindowRecordsItsMissedFrames() {
        let rig = CommitWindowRig()
        let scheduler = rig.makeScheduler()
        rig.commit("newTab.default", at: 20.3)
        #expect(scheduler.sequences.isCommitWindowOpen, "the commit opened no window")
        rig.tick(scheduler, at: [21, 23, 24])
        #expect(!scheduler.sequences.isCommitWindowOpen)
        #expect(rig.samples(.cmdT) == [1, 1])
        #expect(rig.samples(.cmdN) == nil && rig.samples(.cmdW) == nil)
    }

    /// A pointer Close Tab and another key action open windows (the frames after the person's input) but record no
    /// missed frames; a scripted run opens none.
    @Test func otherRunsOpenWindowsButRecordNothing() {
        let rig = CommitWindowRig()
        let scheduler = rig.makeScheduler()
        rig.commit("closeTab", .pointer, at: 20.3)
        rig.tick(scheduler, at: [21, 22, 23])
        rig.commit("splitRight", at: 30.3)
        rig.tick(scheduler, at: [31, 33, 34])
        #expect(rig.ends == 2, "each person's commit should open a window")
        rig.commit("newWindow", .script, at: 40.3)
        #expect(!scheduler.sequences.isCommitWindowOpen, "a scripted run opened a window")
        #expect(HistogramID.Command.allCases.allSatisfy { rig.samples($0) == nil })
    }

    /// Cmd-W's window ends on a tick with no vsyncs while its link is stopped, before it counts a frame, so it reports
    /// nothing; an unrelated window 300 ms later on the same scheduler must not record for Cmd-W. (A stall tick while
    /// the link still runs keeps the window and counts the gap as drops: FrameSequenceTrackerTests.)
    @Test func aWindowThatCountsNoFrameRecordsNothingForItsCommand() throws {
        let rig = CommitWindowRig()
        let scheduler = rig.makeScheduler()
        rig.commit("closeTab", at: 20.3)
        let link = try #require(rig.lastLink, "the commit window made no link")
        link.isPaused = true
        scheduler.frameDidFire(timestamp: CommitWindowRig.base + 20.6 * CommitWindowRig.interval)  // no vsync, link stopped
        link.isPaused = false
        #expect(!scheduler.sequences.isCommitWindowOpen, "the tick with the link stopped did not end the window")
        rig.commit("splitRight", .pointer, at: 38.3)
        rig.tick(scheduler, at: [39, 41, 44])
        #expect(rig.ends == 1)
        #expect(rig.samples(.cmdW) == nil)
    }

    /// Cmd-T's window is on one window's scheduler; a pointer run's window on another closes first and does not take
    /// it, and Cmd-T's own window then records its drop.
    @Test func aWindowOnAnotherSchedulerDoesNotTakeTheCommand() {
        let rig = CommitWindowRig()
        let first = rig.makeScheduler()
        rig.commit("newTab.default", at: 20.3)
        let second = rig.makeScheduler()
        rig.commit("splitRight", .pointer, at: 20.5)
        rig.tick(second, at: [21, 25, 26])
        #expect(rig.samples(.cmdT) == nil, "the other scheduler's window took Cmd-T")
        rig.tick(first, at: [21, 22, 24])
        #expect(rig.samples(.cmdT) == [1, 1])
    }

    /// A later timed command inside an open window takes it: the window counts the frames after both, once.
    @Test func aLaterCommandInAnOpenWindowTakesIt() {
        let rig = CommitWindowRig()
        let scheduler = rig.makeScheduler()
        rig.commit("newTab.default", at: 20.3)
        rig.tick(scheduler, at: [21])
        rig.commit("closeTab", at: 21.3)
        rig.tick(scheduler, at: [22, 23, 24, 25])
        #expect(rig.ends == 1)
        #expect(rig.samples(.cmdW) == [1, 0])
        #expect(rig.samples(.cmdT) == nil)
    }

    /// A burst of 40 Cmd-T presses, each with its own window, records 40 samples: nothing waits in a bounded queue.
    @Test func everyCommandInABurstRecordsOneSample() {
        let rig = CommitWindowRig()
        let scheduler = rig.makeScheduler()
        for press in 0..<40 {
            let at = 20 + Double(press) * 5
            rig.commit("newTab.default", at: at + 0.3)
            rig.tick(scheduler, at: press % 2 == 0 ? [at + 1, at + 2, at + 3] : [at + 1, at + 3])
        }
        #expect(rig.samples(.cmdT) == [40, 20])
    }
}

/// The monitor, its commit windows over a store of their own runtime, and the scheduler the person acts in.
@MainActor
private final class CommitWindowRig {
    static let base: CFTimeInterval = 1000
    static let interval = 1.0 / 60

    let monitor = ActionBudgetMonitor()
    let store: MetricsStore
    let now = MediaNow()
    let current = CurrentScheduler()
    /// Commit windows that closed with a report (any scheduler of the rig).
    private(set) var ends = 0
    /// The fake link the newest scheduler made last.
    private(set) var lastLink: CommitWindowLink?
    private var windows: ActionCommitWindows?

    init() {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: .init(year: 2026, month: 10, day: 26))
        store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        windows = ActionCommitWindows(monitor: monitor, metrics: Metrics(runtime: runtime)) { [current] in current.scheduler }
    }

    /// A scheduler on a fake link of its own clock, now the one the person acts in.
    func makeScheduler() -> FrameScheduler {
        let scheduler = FrameScheduler.testing(clock: ManualClock(), mediaTime: { [now] in now.value }) { [weak self] _ in
            let link = CommitWindowLink()
            self?.lastLink = link
            return link
        }
        current.scheduler = scheduler
        return scheduler
    }

    /// A run of `id` from `entrypoint` committed at refresh `refresh`, through the monitor's hook. Each window that
    /// closes is counted in ``ends`` (wrapping the windows' own report, which they installed at the first commit).
    func commit(_ id: ActionID, _ entrypoint: ActionEntrypoint = .key, at refresh: Double) {
        now.value = Self.base + refresh * Self.interval
        monitor.onCommit?(monitor.intern(id), entrypoint)
        guard let scheduler = current.scheduler, let report = scheduler.sequences.onSequenceEnd,
              current.wrapped.insert(ObjectIdentifier(scheduler)).inserted else { return }
        scheduler.sequences.onSequenceEnd = { [weak self] kind, sequence in
            if kind == .commitWindow { self?.ends += 1 }
            report(kind, sequence)
        }
    }

    /// Link ticks of `scheduler` at each of `refreshes` while it holds its link.
    func tick(_ scheduler: FrameScheduler, at refreshes: [Double]) {
        for refresh in refreshes where scheduler.hasLink {
            scheduler.frameDidFire(timestamp: Self.base + refresh * Self.interval, refreshInterval: Self.interval)
        }
    }

    /// `[count, sum]` of `action.missed_frames.<command>` since launch, nil without a sample.
    func samples(_ command: HistogramID.Command) -> [UInt64]? {
        let name = HistogramID.actionMissedFrames(command).name
        return store.delta().histograms.first { $0.name == name }.map { [$0.count, $0.sum] }
    }
}

@MainActor
private final class CurrentScheduler {
    var scheduler: FrameScheduler?
    var wrapped: Set<ObjectIdentifier> = []
}

@MainActor
private final class MediaNow {
    var value: CFTimeInterval = 1000
}

@MainActor
private final class CommitWindowLink: FrameLink {
    var isPaused = false

    func invalidate() {}
}

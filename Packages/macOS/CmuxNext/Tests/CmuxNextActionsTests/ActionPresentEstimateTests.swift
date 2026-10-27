import CmuxNextSignposts
import CoreFoundation
import CmuxNextWakeups
@testable import CmuxNextActions
import Testing

/// `action.presented_estimate` (``ActionBudgetMonitor/recordPresentEstimate(_:start:commitEnd:inputAgeMilliseconds:)``,
/// p03-rendering 004): a committed run's estimated present is the target of the first tick after its commit, on the
/// vsync grid of the newest tick, in the uptime clock of the run's own times; a monitor with no vsync source records
/// none.
@MainActor
@Suite(.serialized) struct ActionPresentEstimateTests {
    private static let ms: UInt64 = 1_000_000

    @Test func aCommittedRunGetsTheTargetOfTheFirstTickAfterItsCommit() throws {
        // A 100 Hz grid with a vsync at 50 s: ticks at 50.00, 50.01, 50.02 ...
        let grid = DisplayFrameSample(timestamp: 50, interval: 0.01, linkRunning: true)
        var heard: [ActionPresentSignpostMessage] = []
        let monitor = ActionBudgetMonitor(newestFrame: { grid }, presentEstimates: { heard.append($0) })
        let index = monitor.intern("tab.new")
        let start: UInt64 = 50_001 * Self.ms  // 50.001 s
        let commit: UInt64 = 50_004 * Self.ms  // 50.004 s: the first tick after it is 50.01, shown at 50.02
        let message = try #require(monitor.recordPresentEstimate(index, start: start, commitEnd: commit, inputAgeMilliseconds: 1.5))
        #expect(heard == [message])
        #expect(message.id == "tab.new")
        #expect(message.actionIndex == index)
        #expect(message.phase == .running)
        #expect(abs(message.commitMilliseconds - 3) < 1e-6)
        #expect(abs(message.presentMilliseconds - 19) < 1e-3, "50.001 s to 50.02 s")
        #expect(abs(Int64(message.estimateUptimeNanos) - 50_020_000_000) < 1_000, "the estimate in uptime ns")
        #expect(message.traceArg0 == UInt64(index) | VsyncPhase.running.traceCode << 32)
        #expect(monitor.presentEstimateCount == 1)
    }

    /// The app's monitor reads the key display's last tick from the display clock, and makes no link to read it.
    @Test func theAppMonitorReadsTheKeyDisplaysLastTick() throws {
        var made = 0
        let scheduler = FrameScheduler.testing(mediaTime: { 50 }) { _ in
            made += 1
            return EstimateFakeLink()
        }
        let client = FrameClient(owner: "spring", on: scheduler) { _ in true }
        client.activate()
        scheduler.frameDidFire(timestamp: 50, refreshInterval: 0.01, targetTimestamp: 50.01)
        client.deactivate()
        let monitor = ActionBudgetMonitor(board: nil, displays: scheduler.displayClock)
        let message = try #require(monitor.recordPresentEstimate(monitor.intern("tab.new"), start: 50_001 * Self.ms,
                                                                 commitEnd: 50_004 * Self.ms, inputAgeMilliseconds: -1))
        #expect(message.phase == .recent, "the link stopped: its last tick still holds the grid")
        #expect(abs(Int64(message.estimateUptimeNanos) - 50_020_000_000) < 1_000)
        #expect(made == 1 && !scheduler.hasLink)
    }

    @Test func aMonitorWithoutAVsyncSourceRecordsNoEstimate() {
        var heard = 0
        let monitor = ActionBudgetMonitor(presentEstimates: { _ in heard += 1 })
        #expect(monitor.recordPresentEstimate(monitor.intern("tab.new"), start: 0, commitEnd: Self.ms, inputAgeMilliseconds: -1) == nil)
        #expect(heard == 0 && monitor.presentEstimateCount == 0)
    }

    /// With no tick yet, the estimate is the commit plus 1.5 default periods, marked unknown.
    @Test func noTickGivesAnUnknownPhaseGuess() throws {
        let monitor = ActionBudgetMonitor(newestFrame: { nil }, presentEstimates: { _ in })
        let message = try #require(monitor.recordPresentEstimate(monitor.intern("tab.close"), start: 10_000 * Self.ms,
                                                                 commitEnd: 10_002 * Self.ms, inputAgeMilliseconds: -1))
        #expect(message.phase == .unknown)
        #expect(abs(message.presentMilliseconds - (2 + 1.5 * FrameTick.defaultRefreshInterval * 1_000)) < 1e-3)
    }

    /// The registry's runs reach the estimate at their commit boundary; a run whose boundary missed the commit
    /// (idle time) gets none.
    @Test func aRegistryRunRecordsItsEstimateAtTheCommit() throws {
        var heard: [ActionPresentSignpostMessage] = []
        let grid = DisplayFrameSample(timestamp: 1, interval: 1.0 / 120, linkRunning: true)
        let monitor = ActionBudgetMonitor(newestFrame: { grid }, presentEstimates: { heard.append($0) })
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: monitor))
        registry.register(Action(id: "test.present", title: "Present") {})
        #expect(registry.perform("test.present", invocation: ActionInvocation(origin: .mcp)))
        #expect(heard.isEmpty, "estimated before the commit")
        pollingTurn()
        let sample = try #require(monitor.recent(1).first)
        // The estimate follows only a committed run, and only while the action signposts are on.
        let expected = sample.outcome == .committed && Signposter.action.isEnabled ? 1 : 0
        #expect(heard.count == expected)
        if let message = heard.first {
            #expect(message.id == "test.present")
            #expect(message.inputAgeMilliseconds == -1)
            #expect(message.presentMilliseconds >= message.commitMilliseconds)
            #expect(message.estimateUptimeNanos > sample.startUptimeNanos + sample.nanos, "after the commit")
        }
    }

    /// Runs one main run-loop turn that polls and exits without waiting, so the run's commit boundary (its exit
    /// observer) fires. The far-future timer only keeps the mode non-empty.
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }
}

private final class EstimateFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

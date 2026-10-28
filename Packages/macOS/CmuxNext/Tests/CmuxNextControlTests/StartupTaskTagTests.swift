@testable import CmuxNextControl
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreFoundation
import Darwin
import Foundation
import Testing

/// The launch's startup tag: `main()`'s steps and the startup scheduler's running task,
/// with the launch phase, written with one store per step or task and read by the watchdog thread inside a
/// stall's sample, so a stall before startup completion names where the launch was.
@Suite(.serialized, .timeLimit(.minutes(1))) struct StartupTaskTagTests {
    @Test func aStepIsReadByItsStaticNameUntilItEnds() {
        let tag = StartupTaskTag()
        #expect(tag.read() == StartupTaskTag.Reading(packedTask: 0, phase: .beforeFirstFrame, inMain: true))
        tag.step("main.environment")
        #expect(tag.read().taskName == "main.environment")
        tag.step("main.launch_reads")
        #expect(tag.currentTask == "main.launch_reads", "a step replaces the one before it")
        tag.endStep()
        #expect(tag.read().taskName == nil)
    }

    /// The scheduler's task is read while it runs, inside the launch step it runs in; the step is current again after it.
    @MainActor
    @Test func aSchedulerTaskIsReadInsideTheStepItRunsIn() {
        let s = StartupTestScheduler()
        let tag = s.startup.log.tag
        tag.step("app.did_finish_launching")
        let seen = SeenTask()
        s.startup.post(.critical, "ThemeBridge.start", on: .main) { seen.name = tag.currentTask }
        s.hand.drain()
        #expect(seen.name == "ThemeBridge.start")
        #expect(tag.currentTask == "app.did_finish_launching", "the task's end restores the step")
    }

    /// `main` until applicationDidFinishLaunching, `critical` to the first frame, `after_first_frame` to the
    /// completion; no phase once startup completed.
    @MainActor
    @Test func theStallPhaseFollowsTheLaunch() {
        let s = StartupTestScheduler()
        let tag = s.startup.log.tag
        #expect(tag.read().stallPhase == "main")
        tag.appFinishedLaunching()
        #expect(tag.read().stallPhase == "critical")
        s.startup.firstFrameCommitted()
        #expect(tag.read().stallPhase == "after_first_frame")
        s.complete()
        #expect(s.startup.completion != nil)
        #expect(tag.phase == .complete)
        #expect(tag.read().stallPhase == nil)
    }

    @Test func theWatchdogsPublishedTagKeepsTheReading() {
        let tag = StartupTaskTag()
        tag.step("main.daemon_prestart")
        let reading = tag.read()
        #expect(StartupStallTag(reading).reading == reading)
        #expect(StartupStallTag(reading).details == ["startup_phase": .string("main"), "startup_task": .string("main.daemon_prestart")])
        tag.endStep()
        tag.appFinishedLaunching()
        #expect(StartupStallTag(tag.read()).details == ["startup_phase": .string("critical")], "a stall between steps still names its phase")
        #expect(StartupStallTag(nil).details.isEmpty, "a watchdog with no tag adds no field")
    }

    /// Marking a step costs one atomic store: printed in ns per pair, bounded far above what two stores
    /// cost so a loaded runner never fails it, and far below what a lock, an allocation or a string copy
    /// per step would make it.
    @Test func aStepCostsNanoseconds() {
        let tag = StartupTaskTag()
        let count = 200_000
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<count {
            tag.step("bench.step")
            tag.endStep()
        }
        let perPair = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(count)
        print("StartupTaskTag step+endStep: \(String(format: "%.1f", perPair)) ns")
        #expect(perPair < 1_000)
    }

    #if DEBUG
    /// A stall inside a startup scheduler task, before completion: the record names the phase and the
    /// task the scheduler was running when the watchdog sampled it (injected clock, as in
    /// MainThreadWatchdogTests: host load cannot add or miss the stall).
    @MainActor
    @Test func aStallInASchedulerTaskNamesThePhaseAndTheTask() throws {
        let s = StartupTestScheduler()
        s.startup.log.tag.appFinishedLaunching()
        let record = try #require(Self.recordOneStall(tag: s.startup.log.tag) { stall in
            s.startup.post(.critical, "ThemeBridge.start", on: .main) { stall() }
            s.hand.drain()
        })
        #expect(record.details["startup_phase"] == .string("critical"))
        #expect(record.details["startup_task"] == .string("ThemeBridge.start"))
        #expect(s.startup.log.tag.currentTask == nil, "the task ended")
    }

    @MainActor
    @Test func aStallAfterCompletionHasNoStartupTag() throws {
        let s = StartupTestScheduler()
        s.complete()
        let record = try #require(Self.recordOneStall(tag: s.startup.log.tag) { stall in
            s.startup.log.tag.step("late.step")
            stall()
        })
        #expect(record.details["startup_phase"] == nil)
        #expect(record.details["startup_task"] == nil)
    }

    @MainActor
    @Test func aWatchdogWithNoTagRecordsNoStartupFields() throws {
        let record = try #require(Self.recordOneStall(tag: nil) { stall in stall() })
        #expect(record.details["startup_phase"] == nil)
    }

    /// main() before the run loop: each step is its own turn (``MainThreadWatchdog/startupStep(_:)``),
    /// so a stall in one step is listed alone with that step's tag, and short steps add no stall.
    @MainActor
    @Test func aStallInAMainStepIsListedAloneWithThatStepsTag() throws {
        let clock = ManualUptime()
        let sampled = SampleSignal()
        let tag = StartupTaskTag()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false),
                                          startupTasks: tag, uptime: clock.read)
        watchdog.afterSampleForTesting.withLock { $0 = { sampled.fire() } }
        watchdog.start(measuringSinceCreation: true)
        defer { watchdog.stop() }
        let shortSteps: [StaticString] = ["fake.warmup", "fake.environment"]
        for name in shortSteps {
            watchdog.startupStep(name)
            // Under the sample delay (30 ms): the watchdog thread never samples a short step.
            clock.advance(by: .milliseconds(20))
        }
        watchdog.startupStep("fake.launch_stall")
        stallForTestUntilSampled(clock: clock, by: .milliseconds(300), sampled: sampled)
        watchdog.beginCriticalPhase()
        #expect(sampled.hasFired, "the watchdog thread did not sample the stall")
        let records = watchdog.log.records()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.duration == .milliseconds(300), "the stall's own turn, not the steps before it")
        #expect(record.details["startup_phase"] == .string("main"))
        #expect(record.details["startup_task"] == .string("fake.launch_stall"))
        #expect(tag.read().stallPhase == "critical")
        #expect(tag.currentTask == "app.did_finish_launching")
        watchdog.endStartupStep()
        #expect(tag.currentTask == nil)
        #expect(watchdog.mainRunLoopWakes == 0, "a startup turn is not a run-loop wake")
    }

    /// The watchdog is made first in main() and started after the one-thread steps: a stall in those
    /// steps is measured from the watchdog's creation.
    @MainActor
    @Test func aStallBeforeTheStartIsMeasuredFromCreation() throws {
        let clock = ManualUptime()
        let tag = StartupTaskTag()
        tag.step("main.one_thread") // as main() does, before it makes the watchdog
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          startupTasks: tag, uptime: clock.read)
        clock.advance(by: .milliseconds(80))
        watchdog.start(measuringSinceCreation: true)
        defer { watchdog.stop() }
        watchdog.startupStep("main.warmup")
        let record = try #require(watchdog.log.records().first, "the 80 ms before start() was not listed")
        #expect(record.duration == .milliseconds(80))
        #expect(record.details["startup_phase"] == .string("main"), "with no stack sample, the tag at the stall's end")
        #expect(record.details["startup_task"] == .string("main.one_thread"), "the stall names the one-thread step")
        #expect(tag.currentTask == "main.warmup")
    }

    /// AppKit sends applicationDidFinishLaunching inside a run-loop turn the heartbeat opened: the critical
    /// phase's start changes only the tag, so a stall that crosses it is one record over the whole turn,
    /// not two halves under the threshold.
    @MainActor
    @Test func theCriticalPhaseInsideARunLoopTurnDoesNotSplitIt() {
        let clock = ManualUptime()
        let tag = StartupTaskTag()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          startupTasks: tag, uptime: clock.read)
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            clock.advance(by: .milliseconds(40))
            watchdog.beginCriticalPhase()
            clock.advance(by: .milliseconds(40))
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let records = watchdog.log.records()
        #expect(records.count == 1, "the 40 ms + 40 ms turn was split at beginCriticalPhase()")
        #expect(records.first?.duration == .milliseconds(80))
        #expect(records.first?.details["startup_phase"] == .string("critical"))
        #expect(tag.currentTask == "app.did_finish_launching")
    }

    @MainActor
    @Test func aPlainStartMeasuresFromTheStart() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          uptime: clock.read)
        clock.advance(by: .milliseconds(80))
        watchdog.start()
        defer { watchdog.stop() }
        watchdog.beginStartupTurn()
        #expect(watchdog.log.records().isEmpty)
    }

    /// Runs `body` in one main run-loop turn; `body` calls its argument where the 150 ms stall (on the
    /// injected clock) happens. Returns the watchdog's record of it.
    @MainActor
    private static func recordOneStall(tag: StartupTaskTag?,
                                       _ body: @escaping @MainActor (_ stall: @escaping @Sendable () -> Void) -> Void) -> HangRecord? {
        let clock = ManualUptime()
        let sampled = SampleSignal()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false),
                                          startupTasks: tag, uptime: clock.read)
        watchdog.afterSampleForTesting.withLock { $0 = { sampled.fire() } }
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            body { stallForTestUntilSampled(clock: clock, by: .milliseconds(150), sampled: sampled) }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        #expect(sampled.hasFired, "the watchdog thread did not sample the stall")
        return watchdog.log.records().first
    }
    #endif
}

/// What a startup task saw while it ran (main thread).
@MainActor
private final class SeenTask {
    var name: String?
}

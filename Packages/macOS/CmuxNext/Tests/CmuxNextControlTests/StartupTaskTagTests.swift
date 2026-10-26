@testable import CmuxNextControl
import CmuxNextWakeups
import CoreFoundation
import Darwin
import Foundation
import Testing

/// The launch's startup tag (p08-startup-088): the phase and the running startup task, written by
/// the startup scheduler with one store per task start and end, read by the watchdog thread inside
/// a stall's sample, so a stall before startup completion names where the launch was.
@Suite(.serialized, .timeLimit(.minutes(1))) struct StartupTaskTagTests {
    @Test func aTaskIsReadByItsStaticNameUntilItEnds() {
        let tag = StartupTaskTag()
        #expect(tag.read() == StartupTaskTag.Reading(packedTask: 0, phase: .main))
        tag.begin("settings.start")
        #expect(tag.read().taskName == "settings.start")
        #expect(tag.read().phase == .main)
        tag.end()
        #expect(tag.read().taskName == nil)
        let value = tag.run("theme.start") { tag.read().taskName }
        #expect(value == "theme.start")
        #expect(tag.read().taskName == nil, "run ends the task it began")
    }

    @Test func thePhaseOnlyMovesForward() {
        let tag = StartupTaskTag()
        tag.enter(.afterFirstFrame)
        tag.enter(.critical)
        #expect(tag.phase == .afterFirstFrame)
        tag.enter(.complete)
        tag.enter(.afterFirstFrame)
        #expect(tag.phase == .complete)
        #expect(!tag.read().isBeforeCompletion)
    }

    @Test func aStallAfterCompletionCarriesNoStartupFields() {
        let tag = StartupTaskTag()
        tag.begin("late.task")
        #expect(MainThreadWatchdog.details(ofStartup: tag.read()) == ["startup_phase": .string("main"), "startup_task": .string("late.task")])
        tag.enter(.complete)
        #expect(MainThreadWatchdog.details(ofStartup: tag.read()).isEmpty)
        #expect(MainThreadWatchdog.details(ofStartup: StartupTaskTag().read()) == ["startup_phase": .string("main")],
                "a stall between tasks still names its phase")
    }

    /// Marking a startup task costs one atomic store at its start and one at its end: printed in ns
    /// per pair, bounded far above what two stores cost so a loaded runner never fails it, and far
    /// below what a lock, an allocation or a string copy per task would make it.
    @Test func beginAndEndCostNanoseconds() {
        let tag = StartupTaskTag()
        let count = 200_000
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<count {
            tag.begin("bench.task")
            tag.end()
        }
        let perPair = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(count)
        print("StartupTaskTag begin+end: \(String(format: "%.1f", perPair)) ns")
        #expect(perPair < 1_000)
    }

    #if DEBUG
    /// A stall inside a startup task, before completion: the record names the phase and the task
    /// the fake scheduler was running when the watchdog sampled it (injected clock, as in
    /// MainThreadWatchdogTests: host load cannot add or miss the stall).
    @MainActor
    @Test func aStallBeforeCompletionNamesThePhaseAndTheStartupTask() throws {
        let tag = StartupTaskTag()
        tag.enter(.critical)
        let record = try #require(Self.recordOneStall(tag: tag, in: "fake.critical_task"))
        #expect(record.details["startup_phase"] == .string("critical"))
        #expect(record.details["startup_task"] == .string("fake.critical_task"))
        #expect(tag.read().taskName == nil, "the fake scheduler ended its task")
    }

    @MainActor
    @Test func aStallAfterCompletionHasNoStartupTag() throws {
        let tag = StartupTaskTag()
        tag.enter(.complete)
        let record = try #require(Self.recordOneStall(tag: tag, in: "fake.late_task"))
        #expect(record.details["startup_phase"] == nil)
        #expect(record.details["startup_task"] == nil)
    }

    @MainActor
    @Test func aWatchdogWithNoTagRecordsNoStartupFields() throws {
        let record = try #require(Self.recordOneStall(tag: nil, in: "fake.untagged"))
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
        watchdog.enterStartupPhase(.critical)
        #expect(sampled.hasFired, "the watchdog thread did not sample the stall")
        let records = watchdog.log.records()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.duration == .milliseconds(300), "the stall's own turn, not the steps before it")
        #expect(record.details["startup_phase"] == .string("main"))
        #expect(record.details["startup_task"] == .string("fake.launch_stall"))
        #expect(tag.read() == StartupTaskTag.Reading(packedTask: 0, phase: .critical), "the phase ends the last step")
        #expect(watchdog.mainRunLoopWakes == 0, "a startup turn is not a run-loop wake")
    }

    /// The watchdog is made first in main() and started after the one-thread steps: a stall in
    /// those steps is measured from the watchdog's creation.
    @MainActor
    @Test func aStallBeforeTheStartIsMeasuredFromCreation() throws {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false),
                                          startupTasks: StartupTaskTag(), uptime: clock.read)
        clock.advance(by: .milliseconds(80))
        watchdog.start(measuringSinceCreation: true)
        defer { watchdog.stop() }
        watchdog.beginStartupTurn()
        let record = try #require(watchdog.log.records().first, "the 80 ms before start() was not listed")
        #expect(record.duration == .milliseconds(80))
        #expect(record.details["startup_phase"] == .string("main"), "with no stack sample, the tag at the stall's end")
        #expect(record.details["startup_task"] == nil)
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

    /// Runs one 150 ms stall (on the injected clock) inside `name`, posted through a fake startup
    /// scheduler that tags it on `tag`, and returns the watchdog's record of it.
    @MainActor
    private static func recordOneStall(tag: StartupTaskTag?, in name: StaticString) -> HangRecord? {
        let clock = ManualUptime()
        let sampled = SampleSignal()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false),
                                          startupTasks: tag, uptime: clock.read)
        watchdog.afterSampleForTesting.withLock { $0 = { sampled.fire() } }
        watchdog.start()
        defer { watchdog.stop() }
        let scheduler = FakeStartupScheduler(tag: tag ?? StartupTaskTag())
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            scheduler.run(name) { stallForTestUntilSampled(clock: clock, by: .milliseconds(150), sampled: sampled) }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        #expect(sampled.hasFired, "the watchdog thread did not sample the stall")
        return watchdog.log.records().first
    }
    #endif
}

/// The StartupScheduler's side of the tag (p08-startup-010 writes it the same way): each task is
/// tagged while it runs.
private struct FakeStartupScheduler: Sendable {
    let tag: StartupTaskTag

    func run(_ name: StaticString, _ work: () -> Void) {
        tag.run(name, work)
    }
}

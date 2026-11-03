import CoreFoundation
@testable import CmuxNextActions
import Testing

/// The always-on per-action budget (``ActionBudgetMonitor``): every timed run lands in the ring,
/// only an over-budget run reaches an over-budget reader, a missed commit or a nested loop never
/// counts, and the registry's runs are recorded at the commit boundary with their entrypoint.
@MainActor
@Suite(.serialized) struct ActionBudgetMonitorTests {
    private static let ms: UInt64 = 1_000_000

    /// Runs one main run-loop turn that polls and exits without waiting, so the run's commit
    /// boundary (its exit observer) fires. The far-future timer only keeps the mode non-empty.
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test func anOverBudgetRunReachesTheReaderAndAnUnderBudgetOneDoesNot() async throws {
        let monitor = ActionBudgetMonitor(budget: .milliseconds(10))
        var slow = monitor.samples(everyRun: false).makeAsyncIterator()
        monitor.record(monitor.intern("fast"), .key, start: 0, end: 4 * Self.ms, inputAgeMilliseconds: 1, outcome: .committed)
        monitor.record(monitor.intern("slow"), .pointer, start: 10 * Self.ms, end: 25 * Self.ms, inputAgeMilliseconds: 2, outcome: .committed)
        let first = try #require(await slow.next())
        #expect(first.id == "slow", "the under-budget run reached the over-budget reader first")
        #expect(first.sequence == 1)
        #expect(first.entrypoint == .pointer)
        #expect(first.milliseconds == 15)
        #expect(first.inputToCommitMilliseconds == 17)
        #expect(monitor.runCount == 2)
        #expect(monitor.overBudgetCount == 1)
    }

    @Test func aReaderOfEveryRunHearsUnderBudgetRunsToo() async throws {
        let monitor = ActionBudgetMonitor(budget: .milliseconds(10))
        var every = monitor.samples(everyRun: true).makeAsyncIterator()
        monitor.record(monitor.intern("fast"), .key, start: 0, end: Self.ms, inputAgeMilliseconds: -1, outcome: .committed)
        let heard = try #require(await every.next())
        #expect(heard.id == "fast")
        #expect(heard.inputToCommitMilliseconds == nil)
    }

    /// A missed commit holds idle time and a nested loop holds the person's dwell: neither is the
    /// run's work, so neither is over budget however long it took.
    @Test(arguments: [ActionTimingSample.Outcome.missed, .nested])
    func onlyACommittedRunCanBeOverBudget(_ outcome: ActionTimingSample.Outcome) async throws {
        let monitor = ActionBudgetMonitor(budget: .milliseconds(10))
        var slow = monitor.samples(everyRun: false).makeAsyncIterator()
        monitor.record(monitor.intern("dwell"), .pointer, start: 0, end: 900 * Self.ms, inputAgeMilliseconds: -1, outcome: outcome)
        monitor.record(monitor.intern("slow"), .key, start: 0, end: 11 * Self.ms, inputAgeMilliseconds: -1, outcome: .committed)
        let first = try #require(await slow.next())
        #expect(first.id == "slow")
        #expect(monitor.overBudgetCount == 1)
        #expect(monitor.recent(2).map(\.outcome) == [.committed, outcome])
    }

    @Test func theRingKeepsTheNewestRunsNewestFirst() {
        let monitor = ActionBudgetMonitor(capacity: 3)
        #expect(monitor.capacity == 4, "the ring rounds up to a power of two")
        #expect(monitor.batchSize == 2)
        #expect(monitor.recent().isEmpty)
        for index in 0..<10 {
            monitor.record(monitor.intern(ActionID(rawValue: "a\(index)")), .cli, start: 0, end: 1, inputAgeMilliseconds: -1, outcome: .committed)
        }
        #expect(monitor.recent(100).map(\.id.rawValue) == ["a9", "a8", "a7", "a6"])
        #expect(monitor.recent(2).map(\.sequence) == [9, 8])
        #expect(monitor.runCount == 10)
    }

    /// Every run reaches the batch reader once: in batches of half the ring as each half fills,
    /// and the runs since the last batch through `takeUnbatched`, never twice.
    @Test func everyRunReachesTheBatchReaderOnce() async throws {
        let monitor = ActionBudgetMonitor(capacity: 4)
        var batches = monitor.batches().makeAsyncIterator()
        let id = monitor.intern("a")
        func run() { monitor.record(id, .key, start: 0, end: 1, inputAgeMilliseconds: -1, outcome: .committed) }
        run(); run()
        #expect(try #require(await batches.next()).map(\.sequence) == [0, 1])
        run(); run(); run()
        #expect(try #require(await batches.next()).map(\.sequence) == [2, 3])
        #expect(monitor.takeUnbatched().map(\.sequence) == [4])
        run()
        #expect(try #require(await batches.next()).map(\.sequence) == [5], "a taken run was handed over again")
        #expect(monitor.droppedRunCount == 0)
    }

    /// A batch reader that falls behind loses whole batches, counted; memory stays bounded.
    @Test func aBatchReaderThatFallsBehindLosesCountedRuns() {
        let monitor = ActionBudgetMonitor(capacity: 4)
        let stream = monitor.batches()
        let id = monitor.intern("a")
        for _ in 0..<(2 * (ActionBudgetMonitor.batchBuffer + 2)) {
            monitor.record(id, .key, start: 0, end: 1, inputAgeMilliseconds: -1, outcome: .committed)
        }
        #expect(monitor.droppedRunCount == 4, "two batches of two runs did not fit the reader's buffer")
        _ = stream
    }

    @Test func bindingAnActionInternsItOnce() {
        let monitor = ActionBudgetMonitor()
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: monitor))
        registry.register(Action(id: "test.a", title: "A") {})
        registry.register(Action(id: "test.b", title: "B") {})
        let a = registry.action(for: "test.a")?.timingIndex
        #expect(a != nil && a != 0)
        #expect(a != registry.action(for: "test.b")?.timingIndex)
        registry.register(Action(id: "test.a", title: "A again") {})
        #expect(registry.action(for: "test.a")?.timingIndex == a, "a rebind took a new index")
    }

    @Test func aRunEndingBeforeItStartedTakesNoTime() {
        let monitor = ActionBudgetMonitor()
        monitor.record(monitor.intern("x"), .key, start: 5, end: 4, inputAgeMilliseconds: -1, outcome: .committed)
        #expect(monitor.recent(1).first?.nanos == 0)
        #expect(monitor.overBudgetCount == 0)
    }

    /// The registry's run is recorded by the App's timing at the end of the commit after it, with
    /// its entrypoint: nothing is recorded before the turn ends.
    @Test func aRegistryRunIsRecordedAtItsCommitBoundary() async throws {
        let monitor = ActionBudgetMonitor(budget: .zero)
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: monitor))
        var ran = 0
        registry.register(Action(id: "test.run", title: "Run") { ran += 1 })
        var slow = monitor.samples(everyRun: false).makeAsyncIterator()
        #expect(registry.perform("test.run", invocation: ActionInvocation(origin: .mcp)))
        #expect(ran == 1)
        #expect(monitor.runCount == 0, "recorded before the commit")
        pollingTurn()
        #expect(monitor.runCount == 1)
        let sample = try #require(await slow.next())
        #expect(sample.id == "test.run")
        #expect(sample.entrypoint == .mcp)
        #expect(sample.outcome == .committed)
        #expect(sample.inputAgeMilliseconds == -1)
        #expect(sample.startUptimeNanos > 0)
    }

    /// A refused run does no work and records nothing, as for the signposts.
    @Test func aRefusedRunIsNotRecorded() {
        let monitor = ActionBudgetMonitor()
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: monitor))
        registry.register(Action(id: "test.off", title: "Off", isEnabled: { false }) {})
        #expect(!registry.perform("test.off"))
        pollingTurn()
        #expect(monitor.runCount == 0)
    }
}

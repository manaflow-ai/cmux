import CmuxNextActions
import CmuxNextWakeups
import CoreFoundation
@testable import CmuxNextControl
import Testing

/// The off-main half of the per-action budget: the ledger's Release counters, and the Debug log
/// line's stack from the watchdog's over_budget record of the run.
@Suite struct ActionBudgetReporterTests {
    private static let ms: UInt64 = 1_000_000

    private static func sample(_ id: ActionID, _ entrypoint: ActionEntrypoint = .key, start: UInt64 = 100 * ms,
                               ms milliseconds: UInt64, age: Double = -1) -> ActionTimingSample {
        ActionTimingSample(sequence: 0, id: id, entrypoint: entrypoint, startUptimeNanos: start, nanos: milliseconds * ms,
                           inputAgeMilliseconds: age, outcome: .committed)
    }

    private static func record(_ sequence: UInt64, owner: String, start: UInt64, kind: HangRecord.Kind = .overBudget,
                               addresses: [UInt] = [1, 2, 3]) -> HangRecord {
        HangRecord(sequence: sequence, kind: kind, startUptimeNanos: start, duration: .milliseconds(14),
                   cpu: .milliseconds(14), addresses: addresses, details: ["task_owner": .string(owner)])
    }

    private static let frames: @Sendable (HangRecord) -> [HangFrame] = { _ in
        [HangFrame(address: 1, image: "AppKit", symbol: "-[NSView layout]", offset: 4),
         HangFrame(address: 2, image: "cmux", symbol: "PaneController.split()", offset: 8),
         HangFrame(address: 3, image: "cmux", symbol: "SplitHandlers.run()", offset: 12)]
    }

    /// The line takes the stack of the watchdog's `over_budget` record of this run: same action
    /// (`task_owner`) and same start, never another run's or a stall's.
    @Test func theLineUsesTheRunsOwnOverBudgetRecord() {
        let start = 100 * Self.ms
        let line = ActionBudgetLogLine(
            sample: Self.sample("splitRight", start: start, ms: 14, age: 2),
            records: [Self.record(1, owner: "splitRight", start: start - 1),  // an earlier run
                      Self.record(2, owner: "splitDown", start: start),  // another action
                      Self.record(3, owner: "splitRight", start: start, kind: .stall),
                      Self.record(4, owner: "splitRight", start: start)],
            sampling: true, frames: Self.frames, appImage: "cmux")
        #expect(line.text.hasPrefix("action over budget: splitRight key 14.0 ms to commit (input 16.0 ms); main: AppKit -[NSView layout] + 4"))
        #expect(line.text.contains("| app: cmux PaneController.split() + 8 < cmux SplitHandlers.run() + 12"))
        #expect(line.text.hasSuffix("(watchdog over_budget 4)"))
    }

    @Test func withoutTheRunsRecordTheLineSaysWhy() {
        let start = 100 * Self.ms
        let none = ActionBudgetLogLine(sample: Self.sample("newTab", .pointer, start: start, ms: 12), records: [], sampling: true)
        #expect(none.text == "action over budget: newTab pointer 12.0 ms to commit; no main-thread sample: the watchdog recorded no over-budget task for this run")
        let empty = ActionBudgetLogLine(sample: Self.sample("newTab", start: start, ms: 12),
                                        records: [Self.record(1, owner: "newTab", start: start, addresses: [])], sampling: true)
        #expect(empty.text.hasSuffix("; no main-thread sample: the run ended before the watchdog sampled it"))
        let off = ActionBudgetLogLine(sample: Self.sample("newTab", start: start, ms: 12), records: [], sampling: false)
        #expect(off.text.hasSuffix("; no main-thread sample: this build does not sample over-budget tasks"))
    }

    private static let naming = ActionReportNaming(catalog: ["closeTab", "newTab", "splitRight"])

    @Test func theLedgerKeepsALatencyHistogramPerActionAndEntrypoint() async {
        let ledger = ActionBudgetLedger(budgetMilliseconds: 10, naming: Self.naming)
        await ledger.note([Self.sample("closeTab", .key, ms: 11), Self.sample("newTab", .pointer, ms: 1),
                           Self.sample("closeTab", .key, ms: 2), Self.sample("closeTab", .key, ms: 300),
                           Self.sample("closeTab", .cli, ms: 12)])
        var missed = Self.sample("closeTab", .key, ms: 900)
        missed.outcome = .missed
        await ledger.note([missed])
        let counts = await ledger.snapshot(dropped: 7)
        #expect(counts.runsTotal == 6)
        #expect(counts.runsExcluded == 1)
        #expect(counts.runsDropped == 7)
        #expect(counts.overBudgetTotal == 3)
        #expect(counts.rows.map { "\($0.id) \($0.entrypoint) \($0.count)" } == ["closeTab key 3", "closeTab cli 1", "newTab pointer 1"])
        let closeTab = counts.rows[0]
        // Edges 2, 4, 6, 8, 10, 12, 16, 24, 33, 50, 100, 250, then over: 2 ms is the first bucket,
        // 11 ms the sixth (<= 12), 300 ms the last.
        #expect(closeTab.buckets == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1])
        #expect(closeTab.maxMilliseconds == 300)
        guard case .object(let fields) = counts.json else {
            Issue.record("not an object")
            return
        }
        #expect(Set(fields.keys) == ["action_budget_ms", "action_latency_bucket_edges_ms", "action_runs_total", "action_runs_excluded",
                                     "action_runs_dropped", "action_over_budget_total", "action_latency"])
    }

    /// A cmux.json command named with personal text, or any other id outside the catalog, never
    /// reaches the report under its own id.
    @Test func aCustomCommandNamedWithPersonalTextReportsAsCustom() async {
        let ledger = ActionBudgetLedger(budgetMilliseconds: 10, naming: Self.naming)
        await ledger.note([Self.sample("cmuxConfig.deploy-acme-for-jane-doe", ms: 3),
                           Self.sample("cmuxConfig.open ~/Clients/Smith", ms: 4),
                           Self.sample("someExtension.privateThing", ms: 5),
                           Self.sample("splitRight", ms: 6)])
        let counts = await ledger.snapshot(dropped: 0)
        #expect(Set(counts.rows.map(\.id)) == ["custom", "extension", "splitRight"])
        #expect(counts.rows.first { $0.id == "custom" }?.count == 2)
        guard case .object(let fields) = counts.json, case .array(let rows)? = fields["action_latency"] else {
            Issue.record("no rows")
            return
        }
        let text = "\(rows)"
        #expect(!text.contains("jane") && !text.contains("Smith") && !text.contains("privateThing"))
    }
}

/// End to end: a registry run that is slow in its own turn is published on the board, the watchdog
/// records it as an `over_budget` task named by the action, and the Debug line carries that stack.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ActionBudgetSpanTests {
    /// Runs the slow action in one main run-loop turn (a performed block), so its commit boundary fires and the
    /// monitor records it. Synchronous: CFRunLoopRunInMode is unavailable from async contexts.
    @MainActor
    private static func runSlowActionTurn(_ registry: ActionRegistry) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            // main-proof: performed on the main run loop.
            MainActor.assumeIsolated { _ = registry.perform("test.slow") }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
    }

    @MainActor
    @Test func aSlowRegistryRunGetsItsOwnOverBudgetRecordAndLine() async throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        let board = MainTaskBoard()
        watchdog.start()
        defer { watchdog.stop() }
        watchdog.attach(board: board, recordTaskBudgets: true)
        let monitor = ActionBudgetMonitor(budget: .milliseconds(10), board: board)
        let registry = ActionRegistry(catalog: [], runTiming: SignpostActionRunTiming(monitor: monitor))
        registry.register(Action(id: "test.slow", title: "Slow") { spinForTestAction(milliseconds: 40) })
        var slow = monitor.samples(everyRun: false).makeAsyncIterator()
        Self.runSlowActionTurn(registry)
        let sample = try #require(await slow.next())
        #expect(sample.id == "test.slow")
        let record = try #require(watchdog.overBudget.records().last, "the slow run left no over_budget record")
        #expect(record.details["task_owner"] == .string("test.slow"))
        #expect(record.startUptimeNanos == sample.startUptimeNanos)
        let line = ActionBudgetLogLine(sample: sample, records: watchdog.overBudget.records(), sampling: true)
        #expect(line.text.contains("watchdog over_budget"), "\(line.text)")
        #expect(board.running == nil)
    }
}

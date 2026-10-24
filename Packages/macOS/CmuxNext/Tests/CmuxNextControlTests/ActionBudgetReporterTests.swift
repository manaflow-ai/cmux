import CmuxNextActions
@testable import CmuxNextControl
import Testing

/// The off-main half of the per-action budget: the ledger's Release counters, and the Debug log
/// line's attribution to the watchdog's stall sample that overlaps the run.
@Suite struct ActionBudgetReporterTests {
    private static let ms: UInt64 = 1_000_000

    private static func sample(_ id: ActionID, _ entrypoint: ActionEntrypoint = .key, start: UInt64 = 100 * ms,
                               ms milliseconds: UInt64, age: Double = -1) -> ActionTimingSample {
        ActionTimingSample(sequence: 0, id: id, entrypoint: entrypoint, startUptimeNanos: start, nanos: milliseconds * ms,
                           inputAgeMilliseconds: age, outcome: .committed)
    }

    private static func stall(_ sequence: UInt64, start: UInt64, ms milliseconds: Int64, kind: HangRecord.Kind = .stall) -> HangRecord {
        HangRecord(sequence: sequence, kind: kind, startUptimeNanos: start, duration: .milliseconds(milliseconds),
                   cpu: .milliseconds(milliseconds), addresses: [1, 2, 3])
    }

    private static let frames: @Sendable (HangRecord) -> [HangFrame] = { _ in
        [HangFrame(address: 1, image: "AppKit", symbol: "-[NSView layout]", offset: 4),
         HangFrame(address: 2, image: "cmux", symbol: "PaneController.split()", offset: 8),
         HangFrame(address: 3, image: "cmux", symbol: "SplitHandlers.run()", offset: 12)]
    }

    @Test func theLineNamesTheActionItsTimesAndTheOverlappingStallsAppFrames() {
        let line = ActionBudgetLogLine(
            sample: Self.sample("splitRight", start: 100 * Self.ms, ms: 14, age: 2),
            stalls: [Self.stall(1, start: 10 * Self.ms, ms: 20),  // ended before the run
                     Self.stall(2, start: 101 * Self.ms, ms: 12, kind: .busy),  // not a stall
                     Self.stall(3, start: 99 * Self.ms, ms: 14)],
            threshold: .milliseconds(8), frames: Self.frames, appImage: "cmux")
        #expect(line.text.hasPrefix("action over budget: splitRight key 14.0 ms to commit (input 16.0 ms); main: AppKit -[NSView layout] + 4"))
        #expect(line.text.contains("| app: cmux PaneController.split() + 8 < cmux SplitHandlers.run() + 12"))
        #expect(line.text.contains("watchdog stall 3, 14.0 ms"))
    }

    @Test func withNoOverlappingStallTheLineSaysWhy() {
        let late = ActionBudgetLogLine(sample: Self.sample("newTab", .pointer, ms: 12),
                                       stalls: [Self.stall(1, start: 200 * Self.ms, ms: 60)],
                                       threshold: .milliseconds(50), frames: Self.frames, appImage: "cmux")
        #expect(late.text == "action over budget: newTab pointer 12.0 ms to commit; no main-thread sample: the watchdog samples "
            + "stalls of 50.0 ms or more (CMUX_NEXT_HANG_THRESHOLD_MS lowers it)")
        let none = ActionBudgetLogLine(sample: Self.sample("newTab", ms: 12), stalls: [], threshold: nil)
        #expect(none.text.hasSuffix("; no main-thread sample: no watchdog"))
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
        guard case .object(let fields) = counts.json else { return Issue.record("not an object") }
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
            return Issue.record("no rows")
        }
        let text = "\(rows)"
        #expect(!text.contains("jane") && !text.contains("Smith") && !text.contains("privateThing"))
    }
}

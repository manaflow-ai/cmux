import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextMetrics
import CmuxNextTrace
import Testing

/// The ledger's field histograms (p09-observability task 056): `action.commit.<entrypoint>` per committed run,
/// and `action.cmd_t/n/w` for the key runs of New Tab, New Window and Close Tab (their `action.missed_frames` is
/// ActionCommitWindowsTests').
@Suite struct ActionBudgetLedgerTests {
    private static let ms: UInt64 = 1_000_000

    private static let naming = ActionReportNaming(catalog: ["newTab.default", "newWindow", "closeTab", "splitRight"])

    /// A ledger recording into a fresh store of its own runtime, and that store.
    private static func ledger() -> (ActionBudgetLedger, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: .init(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        #expect(store.attach(to: runtime))
        return (ActionBudgetLedger(budgetMilliseconds: 10, naming: naming, metrics: Metrics(runtime: runtime)), store)
    }

    /// A run of `id` that started at `startMs` and committed `durationMs` later.
    private static func run(_ id: ActionID, _ entrypoint: ActionEntrypoint = .key, startMs: UInt64 = 100, durationMs: UInt64,
                            inputAgeMs: Double = -1, outcome: ActionTimingSample.Outcome = .committed) -> ActionTimingSample {
        ActionTimingSample(sequence: 0, id: id, entrypoint: entrypoint, startUptimeNanos: startMs * ms, nanos: durationMs * ms,
                           inputAgeMilliseconds: inputAgeMs, outcome: outcome)
    }

    /// `[count, sum]` of `id` since launch, nil without a sample.
    private static func samples(_ id: HistogramID, in store: MetricsStore) -> [UInt64]? {
        store.delta().histograms.first { $0.name == id.name }.map { [$0.count, $0.sum] }
    }

    @Test func everyCommittedRunRecordsItsEntrypointsCommitHistogram() async {
        let (ledger, store) = Self.ledger()
        await ledger.note([Self.run("splitRight", .key, durationMs: 3), Self.run("splitRight", .pointer, durationMs: 5),
                           Self.run("closeTab", .cli, durationMs: 7), Self.run("cmuxConfig.deploy", .script, durationMs: 2),
                           Self.run("splitRight", .key, durationMs: 900, outcome: .missed),
                           Self.run("splitRight", .mcp, durationMs: 900, outcome: .nested)])
        #expect(Self.samples(.actionCommit(.key), in: store) == [1, 3_000])
        #expect(Self.samples(.actionCommit(.pointer), in: store) == [1, 5_000])
        #expect(Self.samples(.actionCommit(.cli), in: store) == [1, 7_000])
        #expect(Self.samples(.actionCommit(.script), in: store) == [1, 2_000])
        #expect(Self.samples(.actionCommit(.mcp), in: store) == nil, "a nested loop's time is the person's dwell")
    }

    /// Every entrypoint has its own `action.commit` histogram, by the same name.
    @Test func eachEntrypointMapsToTheHistogramOfItsName() {
        for entrypoint in ActionEntrypoint.allCases {
            #expect(HistogramID.actionCommit(HistogramID.Entrypoint(entrypoint)).name == "action.commit." + entrypoint.rawValue)
        }
    }

    /// Cmd-T, New Window and Cmd-W from the keyboard count from the key event to the commit; the same actions from
    /// a click, and other key runs, do not.
    @Test func theTimedCommandsRecordTheirKeyRunsFromTheInput() async {
        let (ledger, store) = Self.ledger()
        await ledger.note([Self.run("newTab.default", durationMs: 4, inputAgeMs: 2),
                           Self.run("newTab.default", startMs: 200, durationMs: 6, inputAgeMs: 1),
                           Self.run("newWindow", durationMs: 9),
                           Self.run("closeTab", .pointer, durationMs: 3),
                           Self.run("splitRight", durationMs: 3, inputAgeMs: 1)])
        #expect(Self.samples(.actionCommand(.cmdT), in: store) == [2, 13_000])
        #expect(Self.samples(.actionCommand(.cmdN), in: store) == [1, 9_000], "no input event: the run's own time")
        #expect(Self.samples(.actionCommand(.cmdW), in: store) == nil)
        #expect(ActionBudgetLedger.command(for: "splitRight") == nil)
    }

    /// Each command's action maps back to it, and the fold records no missed frames (ActionCommitWindows does).
    @Test func eachCommandsActionMapsBackToIt() async {
        for command in HistogramID.Command.allCases {
            #expect(ActionBudgetLedger.command(for: ActionBudgetLedger.actionID(of: command)) == command)
        }
        let (ledger, store) = Self.ledger()
        await ledger.note([Self.run("newTab.default", durationMs: 4), Self.run("closeTab", startMs: 200, durationMs: 2)])
        #expect(Self.samples(.actionMissedFrames(.cmdT), in: store) == nil)
        #expect(Self.samples(.actionMissedFrames(.cmdW), in: store) == nil)
    }
}

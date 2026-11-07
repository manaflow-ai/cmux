import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextControl
import Foundation
import Testing

/// Opt-in usage recording (Leo 2026-11-07): the decision (setting and this Mac's consent), what
/// each focus and action run becomes in the cmux-usage vocabulary (shape only: a cmux.json
/// command's name never leaves), the batch's wire shape, the action tap, and that nothing is
/// produced or sent while it is off.
@MainActor @Suite struct UsageRecorderTests {
    // MARK: Decision

    @Test(arguments: [
        (true, true, false, UsageRecorder.Decision.record),
        (true, false, false, .confirm),
        (false, true, false, .off),
        (false, false, false, .off),
        (true, true, true, .off),
        (true, false, true, .off),
    ])
    func theDecisionNeedsTheSettingAndThisMacsConsentAndNeverInvites(settingOn: Bool, consented: Bool, managedOff: Bool,
                                                                     expected: UsageRecorder.Decision) {
        #expect(UsageRecorder.decision(settingOn: settingOn, consented: consented, managedOff: managedOff) == expected)
    }

    // MARK: Focus

    @Test(arguments: [
        ("terminal", UsageSurface.terminal), ("browserPage", .browser), ("addressBar", .browser), ("findBar", .browser),
        ("devTools", .browser), ("agentPage", .chat), ("page", .page), ("conversation", .conversation),
        ("sidebar", .sidebar), ("sidebarField", .sidebar), ("overlay:palette", .palette), ("overlay:sheet", .overlay),
        ("overlay:rename", .overlay), ("emptyPane", .other), ("textField", .other), ("none", .other),
    ])
    func eachFocusKindFoldsToItsSurface(kind: String, surface: UsageSurface) {
        #expect(UsageSurface(kind: kind) == surface)
    }

    @Test func aTopPageOverTheWorkspaceIsAPage() {
        #expect(UsageSurface(kind: nil) == .page)
    }

    // MARK: Actions

    private static let naming = ActionReportNaming(catalog: ["workspace.select-next"])

    private static func sample(_ id: ActionID, _ entrypoint: ActionEntrypoint, start: UInt64 = 0, nanos: UInt64 = 2_500_000,
                               outcome: ActionTimingSample.Outcome = .committed) -> ActionTimingSample {
        ActionTimingSample(sequence: 0, id: id, entrypoint: entrypoint, startUptimeNanos: start, nanos: nanos,
                           inputAgeMilliseconds: -1, outcome: outcome)
    }

    @Test func aCatalogActionKeepsItsIDAndEntrypointAndCommitTime() {
        #expect(UsageEvent.run(Self.sample("workspace.select-next", .key), naming: Self.naming)
            == .action(id: "workspace.select-next", via: "key", ms: 2.5))
    }

    @Test func aCmuxJSONCommandIsCustomAndAnythingElseOutsideTheCatalogIsExtension() {
        #expect(UsageEvent.run(Self.sample("cmuxConfig.deploy acme-client", .pointer), naming: Self.naming)
            == .action(id: "custom", via: "pointer", ms: 2.5))
        #expect(UsageEvent.run(Self.sample("my.private.thing", .cli), naming: Self.naming)
            == .action(id: "extension", via: "cli", ms: 2.5))
    }

    @Test(arguments: [ActionTimingSample.Outcome.missed, .nested])
    func aRunThatDidNotEndAtItsCommitCountsWithNoTime(outcome: ActionTimingSample.Outcome) {
        #expect(UsageEvent.run(Self.sample("workspace.select-next", .unattributed, outcome: outcome), naming: Self.naming)
            == .action(id: "workspace.select-next", via: "unattributed", ms: 0))
    }

    @Test func eachRunIsStampedWithItsStartInUnixTime() {
        let runs = [Self.sample("workspace.select-next", .key, start: 1_000_000_000), Self.sample("workspace.select-next", .mcp, start: 4_000_000_000)]
        let records = UsageRecord.actions(runs, naming: Self.naming, nowUptimeNanos: 5_000_000_000, nowMilliseconds: 1_762_500_000_000)
        #expect(records.map(\.at) == [1_762_499_996_000, 1_762_499_999_000])
    }

    /// The reporter hands its sink every batch and the runs ``ActionBudgetReporter/counts()`` folds
    /// between batches; a cleared sink hears nothing more.
    @Test func theReportersSinkHearsTheRunsUntilItIsCleared() async {
        let monitor = ActionBudgetMonitor(budget: .milliseconds(10))
        let reporter = ActionBudgetReporter(monitor: monitor, naming: Self.naming, overBudget: nil, sampling: false, logsRuns: false)
        let heard = PortLog()
        reporter.setRunSink { runs in heard.calls.withLock { $0 += runs.map(\.id.rawValue) } }
        let index = monitor.intern("workspace.select-next")
        for start in [UInt64(1), 2, 3] {
            monitor.record(index, .key, start: start * 1_000_000, end: start * 1_000_000 + 500_000, inputAgeMilliseconds: -1, outcome: .committed)
        }
        _ = await reporter.counts()
        #expect(heard.all == ["workspace.select-next", "workspace.select-next", "workspace.select-next"])
        reporter.setRunSink(nil)
        monitor.record(index, .pointer, start: 9_000_000, end: 9_500_000, inputAgeMilliseconds: -1, outcome: .committed)
        _ = await reporter.counts()
        #expect(heard.all.count == 3)
    }

    // MARK: Wire shape

    private static func objects(_ records: [UsageRecord]) throws -> [[String: Any]] {
        let text = try UsageRecord.batch(records)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    @Test func aBatchIsTheTaggedSnakeCaseVocabularyOfCmuxUsage() throws {
        var counts = UsageCounts()
        counts.windows = 2
        counts.maxPanesPerScreen = 3
        counts.sidebarWidth = 240
        let lines = try Self.objects([
            UsageRecord(at: 1, event: .focus(surface: .chat, tab: "tab-1")),
            UsageRecord(at: 2, event: .focus(surface: .sidebar, tab: nil)),
            UsageRecord(at: 3, event: .action(id: "custom", via: "key", ms: 1.5)),
            UsageRecord(at: 4, event: .counts(counts)),
            UsageRecord(at: 5, event: .launch(channel: "nightly", build: "123", prev: "clean")),
            UsageRecord(at: 6, event: .active(on: false)),
        ])
        #expect(lines.map { $0["at"] as? Int } == [1, 2, 3, 4, 5, 6])
        let events = lines.compactMap { $0["ev"] as? [String: Any] }
        #expect(events.count == 6)
        guard events.count == 6 else { return }
        #expect(events[0]["t"] as? String == "focus" && events[0]["surface"] as? String == "chat" && events[0]["tab"] as? String == "tab-1")
        // No tab: no key (serde's `skip_serializing_if`), never null.
        #expect(Set(events[1].keys) == ["t", "surface"])
        #expect(Set(events[2].keys) == ["t", "id", "via", "ms"])
        #expect(Set(events[3].keys) == ["t", "windows", "workspaces", "screens", "panes", "tabs", "terminals", "browsers", "chats",
                                        "max_panes_per_screen", "sidebar_width"])
        #expect(events[3]["t"] as? String == "counts" && events[3]["max_panes_per_screen"] as? Int == 3 && events[3]["sidebar_width"] as? Int == 240)
        #expect(Set(events[4].keys) == ["t", "channel", "build", "prev"])
        #expect(Set(events[5].keys) == ["t", "on"])
    }

    // MARK: On and off

    private static func recorder(_ log: PortLog) -> UsageRecorder {
        let ports = UsageRecorder.Ports(
            channel: "dev", build: "1", previousRun: { "clean" }, counts: { UsageCounts() }, appActive: { true },
            ask: { _, _, _, _ in false },
            setEnabled: { on in log.calls.withLock { $0.append("set-enabled \(on)") } },
            record: { source, _ in log.calls.withLock { $0.append("record \(source)") } })
        return UsageRecorder(ports: ports, managedDisables: { false }, defaults: UserDefaults(suiteName: "cn-usage-\(UUID().uuidString)") ?? .standard)
    }

    @Test func nothingIsProducedOrSentWhileOff() async {
        let log = PortLog()
        let recorder = Self.recorder(log)
        recorder.noteFocus(appActive: true, windowKey: true, kind: "terminal", tab: "t")
        recorder.noteFocus(appActive: false, windowKey: true, kind: "terminal", tab: "t")
        recorder.attach(actions: nil)
        recorder.applicationWillTerminate()
        await Task.yield()
        #expect(!recorder.isRecording)
        #expect(recorder.waitingEvents == 0)
        #expect(log.all.isEmpty)
    }

    @Test func onRecordsTheLaunchAndOnlyKeyWindowFocusChangesAndOffDropsEverything() {
        let recorder = Self.recorder(PortLog())
        recorder.apply(true)
        // The launch, the counts and the app's activity.
        #expect(recorder.waitingEvents == 3)
        recorder.noteFocus(appActive: true, windowKey: true, kind: "terminal", tab: "t")
        recorder.noteFocus(appActive: true, windowKey: true, kind: "terminal", tab: "t")
        recorder.noteFocus(appActive: true, windowKey: false, kind: "agentPage", tab: "other-window")
        #expect(recorder.waitingEvents == 4)
        recorder.noteFocus(appActive: true, windowKey: true, kind: "agentPage", tab: "c")
        #expect(recorder.waitingEvents == 5)
        recorder.apply(false)
        recorder.noteFocus(appActive: true, windowKey: true, kind: "browserPage", tab: "b")
        #expect(!recorder.isRecording)
        #expect(recorder.waitingEvents == 0)
    }

    /// The first decision comes before the daemon connects (Swift review of 3c85b08bff3): a switch
    /// the daemon did not answer is not counted as sent, so the next decision sends it again, and a
    /// failed switch-on ends the on-period instead of leaving a stopped queue that looks on.
    @Test func aFailedSwitchIsSentAgainAndAFailedSwitchOnStopsRecording() async {
        let log = PortLog()
        let failing = PortLog()
        failing.calls.withLock { $0 = ["refuse"] }
        let ports = UsageRecorder.Ports(
            channel: "dev", build: "1", previousRun: { "clean" }, counts: { UsageCounts() }, appActive: { true },
            ask: { _, _, _, _ in false },
            setEnabled: { on in
                if !failing.all.isEmpty { throw Refused() }
                log.calls.withLock { $0.append("set-enabled \(on)") }
            },
            record: { _, _ in })
        let recorder = UsageRecorder(ports: ports, managedDisables: { false },
                                     defaults: UserDefaults(suiteName: "cn-usage-\(UUID().uuidString)") ?? .standard)
        recorder.apply(true)
        for _ in 0..<20 where recorder.isRecording { await Task.yield() }
        #expect(!recorder.isRecording)
        #expect(log.all.isEmpty)

        failing.calls.withLock { $0 = [] }
        recorder.apply(true)
        for _ in 0..<20 where log.all.isEmpty { await Task.yield() }
        #expect(recorder.isRecording)
        #expect(log.all == ["set-enabled true"])

        recorder.apply(false)
        for _ in 0..<20 where log.all.count < 2 { await Task.yield() }
        #expect(log.all == ["set-enabled true", "set-enabled false"])
    }

    // MARK: Queue

    @Test func aStoppedQueueKeepsAndSendsNothing() async {
        let log = PortLog()
        let queue = UsageEventQueue { _ in log.calls.withLock { $0.append("record") } }
        queue.stage([UsageRecord(at: 1, event: .active(on: true))])
        queue.stop()
        queue.stage([UsageRecord(at: 2, event: .active(on: false))])
        await queue.flush()
        #expect(queue.count == 0)
        #expect(log.all.isEmpty)
    }

    @Test func aFlushSendsOneArrayAndAFailedOneIsKeptForTheNext() async throws {
        let log = PortLog()
        let refusing = PortLog()
        refusing.calls.withLock { $0 = ["refuse"] }
        let queue = UsageEventQueue { events in
            if !refusing.all.isEmpty { throw Refused() }
            log.calls.withLock { $0.append(events) }
        }
        queue.stage([UsageRecord(at: 1, event: .active(on: true)), UsageRecord(at: 2, event: .active(on: false))])
        await queue.flush()
        #expect(queue.count == 2)
        refusing.calls.withLock { $0 = [] }
        await queue.flush()
        #expect(queue.count == 0)
        #expect(log.all.count == 1)
        let lines = try #require(JSONSerialization.jsonObject(with: Data((log.all.first ?? "").utf8)) as? [[String: Any]])
        #expect(lines.map { $0["at"] as? Int } == [1, 2])
    }
}

/// What a fake port or sink was handed, from any thread.
private final class PortLog: Sendable {
    let calls = Mutex<[String]>([])
    var all: [String] { calls.withLock { $0 } }
}

/// A send the daemon refused.
private struct Refused: Error {}

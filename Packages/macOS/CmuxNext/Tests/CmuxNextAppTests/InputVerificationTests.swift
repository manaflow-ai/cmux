@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// The journal, replay, reports and world invariants
/// (plans/cmux-next/input-spec.md sections 3-5).
struct InputVerificationTests {
    typealias R = FocusReducerTests
    typealias Entry = InputJournalEntry

    // MARK: Journal

    @Test func disabledJournalRecordsNothingAndBuildsNoPayload() {
        let journal = InputJournal(capacity: 16)
        var built = false
        journal.append(window: "w", { built = true; return .marker("x") }())
        #expect(!built)
        #expect(journal.entries().isEmpty)
    }

    @Test func ringKeepsTheNewestEntriesInOrder() {
        let journal = InputJournal(capacity: 16)
        journal.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        for index in 0..<40 { journal.append(window: nil, .marker("\(index)")) }
        let entries = journal.entries()
        #expect(entries.count == 16)
        #expect(entries.first?.kind == .marker("24"))
        #expect(entries.last?.kind == .marker("39"))
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.seq + 1 == $1.seq && $0.uptimeNanos <= $1.uptimeNanos })
        #expect(journal.stats.overwritten == 24)
        #expect(journal.entries(last: 3).map(\.kind) == [.marker("37"), .marker("38"), .marker("39")])
    }

    @Test func dragsAndScrollsMergeIntoOneEntry() {
        let journal = InputJournal(capacity: 16)
        journal.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        func mouse(_ phase: Entry.MousePhase, _ x: Double, dy: Double = 0) -> Entry.Mouse {
            Entry.Mouse(phase: phase, button: 0, x: x, y: 0, clickCount: 0, modifiers: [], dy: dy)
        }
        journal.appendMouse(window: "w", mouse(.down, 1))
        for x in 2...9 { journal.appendMouse(window: "w", mouse(.drag, Double(x))) }
        journal.appendMouse(window: "w", mouse(.up, 9))
        journal.appendMouse(window: "w", mouse(.scroll, 9, dy: 2))
        journal.appendMouse(window: "w", mouse(.scroll, 9, dy: 3))
        let kinds = journal.entries().map(\.kind)
        #expect(kinds.count == 4)
        guard case .mouse(let drag) = kinds[1], case .mouse(let scroll) = kinds[3] else { Issue.record("\(kinds)"); return }
        #expect(drag.count == 8 && drag.x == 9)
        #expect(scroll.count == 2 && scroll.dy == 5)
    }

    @Test(arguments: [
        (false, nil as String?, [:] as [String: String], false, false),
        (true, nil, [:], true, false),
        (false, "tag", [:], true, false),
        (false, nil, ["CMUX_NEXT_INPUT_JOURNAL": "1"], true, false),
        (true, "tag", ["CMUX_NEXT_INPUT_JOURNAL": "0"], false, false),
        (true, nil, ["CMUX_NEXT_INPUT_JOURNAL_CHARACTERS": "1"], true, true),
        (false, nil, ["CMUX_NEXT_INPUT_JOURNAL_CHARACTERS": "1"], false, false),
    ])
    func journalPolicy(debug: Bool, tag: String?, environment: [String: String], enabled: Bool, characters: Bool) {
        let policy = InputJournalPolicy.resolve(isDebugBuild: debug, tag: tag, environment: environment)
        #expect(policy == InputJournalPolicy(enabled: enabled, recordsCharacters: characters))
    }

    // MARK: Replay

    /// A coordinator journaling like `AppServices.observeFocus`.
    static func journaled(_ events: [FocusEvent], checkpointEvery interval: Int = 64) -> [Entry] {
        let journal = InputJournal(capacity: 4_096)
        journal.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        let coordinator = FocusCoordinator()
        var since = Int.max
        coordinator.observer = { observation in
            guard case .reduced(let event, let before, let after) = observation else { return }
            if since >= interval {
                since = 0
                journal.append(window: "w", .focusCheckpoint(before))
            }
            since += 1
            journal.append(window: "w", .focus(event, after: FocusDigest(after)))
        }
        events.forEach(coordinator.send)
        return journal.entries()
    }

    static let events: [FocusEvent] = [
        .windowKey(true), .topology(R.topology()), .focusPane("b", source: .mouse), .focusTarget(.addressBar, source: .keyboard),
        .overlayOpened(.palette), .focusPane("c", source: .palette), .overlayClosed(.palette), .dragBegan(tabs: ["t3"], pane: "c"),
        .dragEnded(.cancelled), .responder(.sidebar, source: .keyboard), .focusPane("a", source: .cli),
    ]

    @Test func replayOfAJournalMatchesItsRecording() {
        let result = InputReplay.replay(Self.journaled(Self.events))
        #expect(result.firstDivergence == nil)
        #expect(result.focusEvents == Self.events.count)
        #expect(result.windows == ["w"])
    }

    @Test func replayReportsTheFirstDivergentStep() {
        var entries = Self.journaled(Self.events)
        guard let index = entries.firstIndex(where: { if case .focus(.focusPane("c", _, _), _) = $0.kind { true } else { false } }),
              case .focus(let event, var digest) = entries[index].kind else { Issue.record("no focusPane entry"); return }
        digest.pane = "a"
        entries[index].kind = .focus(event, after: digest)
        let divergence = InputReplay.replay(entries).firstDivergence
        #expect(divergence?.kind == .outcome)
        #expect(divergence?.seq == entries[index].seq)
    }

    @Test func replayStartsAtACheckpointMidRing() {
        let entries = Self.journaled(Self.events + Self.events.dropFirst(2), checkpointEvery: 4)
        let tail = Array(entries.drop { if case .focusCheckpoint = $0.kind { false } else { true } }.dropFirst(3))
        let result = InputReplay.replay(tail)
        #expect(result.firstDivergence == nil)
        #expect(result.skippedFocusEvents > 0)
        #expect(result.focusEvents > 0)
    }

    @Test func replayFlagsAnInvariantBrokenByARecordedState() {
        var bad = R.loaded()
        bad.pane = "gone"
        let entries = [Entry(seq: 1, uptimeNanos: 1, window: "w", kind: .focusCheckpoint(bad)),
                       Entry(seq: 2, uptimeNanos: 2, window: "w", kind: .focus(.appActive(true), after: FocusDigest(FocusReducer.reduce(bad, .appActive(true)).0)))]
        let divergence = InputReplay.replay(entries).firstDivergence
        #expect(divergence?.kind == .invariant)
        #expect(divergence?.violations.contains { $0.invariant == .livePane } == true)
    }

    @Test func attachReplayFollowsTheMachine() {
        var machine = TerminalAttachMachine<Int>(initialSize: CellSize(cols: 80, rows: 24))
        var entries: [Entry] = []
        let script: [(TerminalAttachMachine<Int>.Event, String, Int?, Int?, Int)] = [
            (.start, "start", nil, nil, 0), (.input(Data([1, 2])), "input", nil, nil, 2), (.opened(7, attempt: 1), "opened", 7, 1, 0),
            (.replayDelivered(7), "replay", 7, nil, 0), (.input(Data([3])), "input", nil, nil, 1), (.ended(7, .overflow), "ended:overflow", 7, nil, 0),
            (.input(Data([4])), "input", nil, nil, 1), (.opened(8, attempt: 2), "opened", 8, 2, 0), (.replayDelivered(8), "replay", 8, nil, 0),
            (.close, "close", nil, nil, 0),
        ]
        for (index, (event, name, link, attempt, bytes)) in script.enumerated() {
            _ = machine.reduce(event)
            entries.append(Entry(seq: UInt64(index + 1), uptimeNanos: UInt64(index), window: nil, kind: .attach(.init(
                surface: "s1", event: name, link: link, attempt: attempt, bytes: bytes, phase: machine.phase.journalName))))
        }
        let result = InputReplay.replay(entries)
        #expect(result.firstDivergence == nil)
        #expect(result.attachEvents == script.count)
    }

    // MARK: Reports and world invariants

    @Test func desyncReportRoundTrips() throws {
        let observation = InputFuzzerSupport.observation()
        let report = DesyncReport(id: "desync-1", sequence: 1, createdAt: Date(timeIntervalSince1970: 1_000), uptimeNanos: 5, tag: "t",
                                  violations: [InputViolation(invariant: .responderMatches, window: "W0", detail: "x")],
                                  observation: observation, journal: Self.journaled(Self.events),
                                  journalStats: InputJournal(capacity: 16).stats)
        let data = try DesyncReport.encoder.encode(report)
        #expect(try DesyncReport.decoder.decode(DesyncReport.self, from: data) == report)
    }

    @Test func worldCatchesAResponderAndKeyWindowDesync() {
        var observation = InputFuzzerSupport.observation()
        #expect(InputInvariants.world(observation).violations.isEmpty)
        observation.windows[0].responder = .sidebar
        observation.keyWindow = .childPage(window: "W0")
        observation.windows[0].isKey = false
        let ids = Set(InputInvariants.world(observation).violations.map(\.invariant))
        #expect(ids.isSuperset(of: [.responderMatches, .keyWindowOwned, .ghosttyMatches]))
    }

    // MARK: Window frames

    @Test func windowFramesMergeIntoOneEntry() {
        let journal = InputJournal(capacity: 16)
        journal.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        for x in 0..<5 { journal.appendWindowFrame(window: "w", (Double(x), 0, 800, 600)) }
        journal.appendWindowFrame(window: "v", (1, 2, 3, 4))
        journal.append(window: "w", .marker("m"))
        journal.appendWindowFrame(window: "w", (9, 9, 800, 600))
        #expect(journal.entries().map(\.kind) == [.windowFrame(x: 4, y: 0, width: 800, height: 600),
                                                   .windowFrame(x: 1, y: 2, width: 3, height: 4), .marker("m"),
                                                   .windowFrame(x: 9, y: 9, width: 800, height: 600)])
    }
}

/// A consistent one-window observation built by the composed model.
enum InputFuzzerSupport {
    static func observation() -> InputObservation {
        let world = InputWorld(windows: 1, reportsRemoval: false)
        world.frame()
        return world.observation()
    }
}

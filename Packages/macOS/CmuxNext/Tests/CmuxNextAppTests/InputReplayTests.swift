@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextInputModel
import Foundation
import Testing

/// `InputReplay` and `AttachOracle` in CmuxNextInputModel
/// (plans/cmux-next/input-spec.md section 5): the replay is a value over the
/// entries it is given, and `debug.replay` encodes its `Result` with
/// `DesyncReport.encoder`, so the JSON below is the method's output.
struct InputReplayTests {
    typealias Entry = InputJournalEntry
    typealias Machine = TerminalAttachMachine<Int>

    // MARK: Attach

    /// One terminal: input queued while attaching, a live link, an overflow
    /// that re-attaches on a second link with input queued again, a close.
    static let attachScript: [(event: Machine.Event, name: String, link: Int?, attempt: Int?, bytes: Int)] = [
        (.start, "start", nil, nil, 0), (.input(Data([1, 2])), "input", nil, nil, 2), (.opened(7, attempt: 1), "opened", 7, 1, 0),
        (.replayDelivered(7), "replay", 7, nil, 0), (.input(Data([3])), "input", nil, nil, 1), (.ended(7, .overflow), "ended:overflow", 7, nil, 0),
        (.input(Data([4])), "input", nil, nil, 1), (.opened(8, attempt: 2), "opened", 8, 2, 0), (.replayDelivered(8), "replay", 8, nil, 0),
        (.close, "close", nil, nil, 0),
    ]

    /// The journal `InputJournal.attachObserver` writes for `attachScript`:
    /// each record carries the phase the real machine reached.
    static func attachJournal(surface: String = "s1") -> [Entry] {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        return attachScript.enumerated().map { index, step in
            _ = machine.reduce(step.event)
            return Entry(seq: UInt64(index + 1), uptimeNanos: UInt64(index), window: nil, kind: .attach(.init(
                surface: surface, event: step.name, link: step.link, attempt: step.attempt, bytes: step.bytes,
                phase: machine.phase.journalName)))
        }
    }

    static func json(_ value: some Encodable) throws -> String {
        String(decoding: try DesyncReport.encoder.encode(value), as: UTF8.self)
    }

    @Test func attachReplayFollowsTheMachine() throws {
        let result = InputReplay(Self.attachJournal()).run()
        #expect(result.firstDivergence == nil, "\(String(describing: result.firstDivergence))")
        #expect(result.attachEvents == Self.attachScript.count)
        #expect(try Self.json(result)
            == #"{"attachEvents":10,"divergences":0,"focusEvents":0,"skippedAttachEvents":0,"skippedFocusEvents":0,"windows":[]}"#)
    }

    @Test func attachReplayNamesTheFirstWrongPhase() throws {
        var entries = Self.attachJournal()
        guard case .attach(var record) = entries[2].kind else { Issue.record("entry 3 is not an attach record"); return }
        let replayed = record.phase
        record.phase = "bogus"
        entries[2].kind = .attach(record)
        let result = InputInvariants.replay(entries).run()
        // The replay reduces events, not recorded phases: only the corrupted step diverges.
        #expect(result.divergences == 1)
        let divergence = try #require(result.firstDivergence)
        #expect(try Self.json(divergence)
            == #"{"event":"s1 opened","kind":"outcome","recorded":"bogus","replayed":"\#(replayed)","seq":3,"violations":[]}"#)
    }

    @Test func attachEventsWithoutTheirStartAreSkipped() {
        let tail = Array(Self.attachJournal().dropFirst())
        let result = InputInvariants.replay(tail).run()
        #expect(result.attachEvents == 0)
        #expect(result.skippedAttachEvents == tail.count)
        #expect(result.firstDivergence == nil)
    }

    @Test func terminalsReplayIndependently() {
        let entries = Self.attachJournal(surface: "s1") + Self.attachJournal(surface: "s2")
        let result = InputInvariants.replay(entries).run()
        #expect(result.firstDivergence == nil)
        #expect(result.attachEvents == 2 * Self.attachScript.count)
    }

    @Test func oracleCatchesASendOnADetachedLink() {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24))
        var oracle = AttachOracle<Int>()
        for event in [Machine.Event.start, .opened(7, attempt: 1), .replayDelivered(7)] {
            let before = machine
            let effects = machine.reduce(event)
            #expect(oracle.observe(event, before: before, after: machine, effects: effects).isEmpty)
        }
        let before = machine
        let violations = oracle.observe(.input(Data([9])), before: before, after: machine,
                                        effects: [.detach(7), .send(7, Data([9]))], surface: "s1")
        #expect(violations.contains { $0.invariant == .liveLinkOnly })
    }

    // MARK: Focus

    static let topology = FocusTopology(workspace: "ws", panes: [
        .init(id: "p1", tabs: [.init(id: "t1", kind: .terminal)], selected: "t1"),
        .init(id: "p2", tabs: [.init(id: "t2", kind: .terminal)], selected: "t2"),
    ])

    static let focusEvents: [FocusEvent] = [
        .windowKey(true), .appActive(true), .topology(topology), .focusPane("p1", source: .mouse), .overlayOpened(.palette),
        .focusPane("p2", source: .palette), .overlayClosed(.palette),
    ]

    /// A window's journal as `InputVerificationService` writes it: a
    /// checkpoint, then each event with the digest of the state it produced.
    static func focusJournal() throws -> [Entry] {
        let machine = FocusMachine()
        let checkpoint = machine.checkpoint()
        var state = try #require(machine.restore(checkpoint))
        var entries = [Entry(seq: 1, uptimeNanos: 1, window: "w", kind: .focusCheckpoint(checkpoint))]
        for event in focusEvents {
            _ = machine.send(event, into: &state)
            let seq = UInt64(entries.count + 1)
            entries.append(Entry(seq: seq, uptimeNanos: seq, window: "w", kind: .focus(event, after: FocusDigest(state))))
        }
        return entries
    }

    @Test func focusReplayMatchesItsRecording() throws {
        let result = InputInvariants.replay(try Self.focusJournal()).run()
        #expect(result.firstDivergence == nil, "\(String(describing: result.firstDivergence))")
        #expect(result.focusEvents == Self.focusEvents.count)
        #expect(result.windows == ["w"])
    }

    @Test func focusReplayReportsTheFirstDivergentStep() throws {
        var entries = try Self.focusJournal()
        let index = try #require(entries.firstIndex { entry in
            if case .focus(.focusPane("p1", _, _), _) = entry.kind { true } else { false }
        })
        guard case .focus(let event, var digest) = entries[index].kind else { Issue.record("no focusPane entry"); return }
        digest.pane = "p2"
        entries[index].kind = .focus(event, after: digest)
        let divergence = try #require(InputInvariants.replay(entries).run().firstDivergence)
        #expect(divergence.kind == .outcome)
        #expect(divergence.seq == entries[index].seq)
        #expect(divergence.window == "w")
    }

    @Test func focusEventsBeforeTheFirstCheckpointAreSkipped() throws {
        let tail = Array(try Self.focusJournal().dropFirst())
        let result = InputInvariants.replay(tail).run()
        #expect(result.focusEvents == 0)
        #expect(result.skippedFocusEvents == Self.focusEvents.count)
        #expect(result.windows.isEmpty)
    }

    /// `debug.replay` and an offline replayer read the same entries: the
    /// same journal gives byte-identical output, run after run.
    @Test func sameEntriesGiveIdenticalOutput() throws {
        let entries = try Self.focusJournal() + Self.attachJournal()
        let first = try Self.json(InputInvariants.replay(entries).run())
        let decoded = try DesyncReport.decoder.decode([Entry].self, from: DesyncReport.encoder.encode(entries))
        #expect(try Self.json(InputInvariants.replay(decoded).run()) == first)
        #expect(try Self.json(InputInvariants.replay(entries).run()) == first)
    }
}

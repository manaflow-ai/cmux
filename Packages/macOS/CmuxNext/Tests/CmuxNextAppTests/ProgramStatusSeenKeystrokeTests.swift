import CmuxNextBridge
import CmuxNextDaemon
import Testing

/// Every key-down in a terminal marks its tab's OSC 7501 records seen (NotificationCenterService.noteTyping).
/// A look that changes nothing answers from the seen set's index, so it costs the tab's records, not the
/// 1024 keys the set may hold; and the answers stay those of the full rule: a new or re-reported record
/// is still taken, and a terminal's key for a record it no longer has is still dropped.
@Suite struct ProgramStatusSeenKeystrokeTests {
    static func done(_ id: String, seq: UInt64) -> ProgramStatusRecord {
        ProgramStatusRecord(id: id, state: .done, updatedSeq: seq)
    }

    /// 1023 other terminals' keys and this terminal's two records, already seen.
    static func full() -> ProgramStatusSeen {
        var seen = ProgramStatusSeen()
        for index in 0..<1023 { seen.markSeen([done("r", seq: 1)], terminal: "terminal:other-\(index)") }
        seen.markSeen([done("a", seq: 1), done("b", seq: 2)], terminal: "terminal:me")
        return seen
    }

    @Test func aRepeatedLookChangesNothing() {
        var seen = Self.full()
        let before = seen
        #expect(!seen.markSeen([Self.done("a", seq: 1), Self.done("b", seq: 2)], terminal: "terminal:me"))
        #expect(seen == before)
        #expect(seen.hasKeys(of: "terminal:me"))
        #expect(!seen.hasKeys(of: "terminal:nobody"))
    }

    @Test func aReReportedRecordIsUnseenUntilLookedAt() {
        var seen = Self.full()
        let again = [Self.done("a", seq: 1), Self.done("b", seq: 3)]
        #expect(seen.visible(again, terminal: "terminal:me").map(\.id) == ["b"])
        #expect(seen.markSeen(again, terminal: "terminal:me"))
        #expect(seen.visible(again, terminal: "terminal:me").isEmpty)
    }

    @Test func aRecordTheTerminalNoLongerHasLosesItsKey() {
        var seen = Self.full()
        #expect(seen.markSeen([Self.done("a", seq: 1)], terminal: "terminal:me"))
        // "b" is gone from the terminal: reported again later with the same seq, it is unseen.
        #expect(seen.visible([Self.done("b", seq: 2)], terminal: "terminal:me").map(\.id) == ["b"])
    }

    @Test func aLookAtATerminalWithNoRecordsDropsItsKeys() {
        var seen = Self.full()
        #expect(seen.markSeen([], terminal: "terminal:me"))
        #expect(!seen.hasKeys(of: "terminal:me"))
        #expect(!seen.markSeen([], terminal: "terminal:me"))
    }
}

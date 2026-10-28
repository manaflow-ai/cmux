@testable import CmuxNextBridge
import CmuxNextDaemon
import Testing

/// Every key-down in a terminal marks its tab's OSC 7501 records seen (NotificationCenterService.noteTyping).
/// A look that changes nothing must cost the tab's records, not the up to 1024 keys the seen set holds: the keys
/// it reads (`keysRead`) do not grow with the other terminals' keys. The answers stay those of the full rule: a new
/// or re-reported record is still taken, and a terminal's key for a record it no longer has is dropped.
@Suite struct ProgramStatusSeenKeystrokeTests {
    static func done(_ id: String, seq: UInt64) -> ProgramStatusRecord {
        ProgramStatusRecord(id: id, state: .done, updatedSeq: seq)
    }

    /// `others` other terminals' keys and this terminal's two records, already seen.
    static func seen(others: Int) -> ProgramStatusSeen {
        var seen = ProgramStatusSeen()
        for index in 0..<others { seen.markSeen([done("r", seq: 1)], terminal: "terminal:other-\(index)") }
        seen.markSeen([done("a", seq: 1), done("b", seq: 2)], terminal: "terminal:me")
        return seen
    }

    /// Seen keys one look that changes nothing reads, with `others` other terminals' keys in the set.
    static func keysReadByARepeatedLook(others: Int) -> Int {
        var seen = seen(others: others)
        let before = seen.keysRead
        let changed = seen.markSeen([done("a", seq: 1), done("b", seq: 2)], terminal: "terminal:me")
        #expect(!changed)
        return seen.keysRead - before
    }

    /// O(the tab's records): a look reads this tab's 2 keys whether 30 or 1022 other keys are in the set (the
    /// O(keys) look read every key: 32 and 1024).
    @Test func aLookThatChangesNothingDoesNotGrowWithOtherTerminalsKeys() {
        let few = Self.keysReadByARepeatedLook(others: 30)
        let many = Self.keysReadByARepeatedLook(others: 1022)
        #expect(few == 2, "a look read \(few) keys with 30 other keys (want this tab's 2)")
        #expect(many == 2, "a look read \(many) keys with 1022 other keys (want this tab's 2)")
    }

    @Test func aRepeatedLookChangesNothing() {
        var seen = Self.seen(others: 1022)
        let before = seen
        let changed = seen.markSeen([Self.done("a", seq: 1), Self.done("b", seq: 2)], terminal: "terminal:me")
        #expect(!changed)
        #expect(seen == before)
    }

    @Test func aReReportedRecordIsUnseenUntilLookedAt() {
        var seen = Self.seen(others: 1022)
        let again = [Self.done("a", seq: 1), Self.done("b", seq: 3)]
        #expect(seen.visible(again, terminal: "terminal:me").map(\.id) == ["b"])
        let changed = seen.markSeen(again, terminal: "terminal:me")
        #expect(changed)
        #expect(seen.visible(again, terminal: "terminal:me").isEmpty)
    }

    @Test func aRecordTheTerminalNoLongerHasLosesItsKey() {
        var seen = Self.seen(others: 1022)
        let changed = seen.markSeen([Self.done("a", seq: 1)], terminal: "terminal:me")
        #expect(changed)
        // "b" is gone from the terminal: reported again later with the same seq, it is unseen.
        #expect(seen.visible([Self.done("b", seq: 2)], terminal: "terminal:me").map(\.id) == ["b"])
    }

    @Test func aLookAtATerminalWithNoRecordsDropsItsKeys() {
        var seen = Self.seen(others: 1022)
        let first = seen.markSeen([], terminal: "terminal:me")
        #expect(first)
        #expect(seen.visible([Self.done("a", seq: 1)], terminal: "terminal:me").map(\.id) == ["a"])
        let second = seen.markSeen([], terminal: "terminal:me")
        #expect(!second)
    }
}

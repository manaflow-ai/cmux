import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// Every key-down in a terminal marks its tab's OSC 7501 records seen (NotificationCenterService.noteTyping).
/// A look that changes nothing must cost the tab's records, not the up to 1024 keys the seen set holds:
/// its time does not grow with the other terminals' keys. The answers stay those of the full rule: a new
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

    /// The fastest of five runs of `looks` repeated looks that change nothing, in seconds.
    static func repeatedLooks(others: Int, looks: Int = 4000) -> Double {
        var seen = seen(others: others)
        let records = [done("a", seq: 1), done("b", seq: 2)]
        var best = Double.infinity
        for _ in 0..<5 {
            let start = ContinuousClock.now
            var changed = 0
            for _ in 0..<looks where seen.markSeen(records, terminal: "terminal:me") { changed += 1 }
            let elapsed = ContinuousClock.now - start
            #expect(changed == 0)
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        return best
    }

    /// O(the tab's records): a look with 1022 other keys costs about what it costs with 30
    /// (an O(keys) look costs ~30x; the bound leaves room for timer noise).
    @Test func aLookThatChangesNothingDoesNotGrowWithOtherTerminalsKeys() {
        let few = Self.repeatedLooks(others: 30)
        let many = Self.repeatedLooks(others: 1022)
        #expect(many < few * 4 + 0.002,
                "4000 looks: \(Int(few * 1e6)) us with 30 other keys, \(Int(many * 1e6)) us with 1022 (want no growth)")
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

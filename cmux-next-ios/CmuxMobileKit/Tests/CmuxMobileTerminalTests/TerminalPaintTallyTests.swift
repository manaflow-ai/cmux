import Foundation
import Testing
@testable import CmuxMobileTerminal

@Suite struct TerminalPaintTallyTests {
    @Test func aRedrawIsPaintedByTheFirstPresentPastItsBytes() {
        var tally = TerminalPaintTally()
        tally.handed(100)
        tally.mark(seq: 1, receivedMs: 1000)
        tally.handed(50)
        tally.mark(seq: 2, receivedMs: 1004)
        // Parsed only the first line's bytes: the second waits.
        tally.presented(parsed: 100, atMs: 1009)
        tally.presented(parsed: 150, atMs: 1025)
        #expect(tally.pending == [[1, 1000, 1009], [2, 1004, 1025]])
        let paint = TerminalPaintTally.receiveToPaint(tally.pending)
        #expect(paint?.p50 == 9)
        #expect(paint?.p95 == 21)
    }

    @Test func aReportGoesAtItsSizeOrItsAgeAndIsBounded() {
        var tally = TerminalPaintTally()
        #expect(tally.takeReport(nowMs: 0) == nil)
        for seq in 1...(TerminalPaintTally.maxSamples + 10) {
            tally.handed(1)
            tally.mark(seq: seq, receivedMs: Double(seq))
        }
        tally.presented(parsed: Int.max, atMs: 500)
        let report = tally.takeReport(nowMs: 500)
        #expect(report?.count == TerminalPaintTally.maxSamples)
        #expect(report?.first?.first == 1)
        // The rest waits for its age.
        #expect(tally.takeReport(nowMs: 501) == nil)
        #expect(tally.takeReport(nowMs: 501 + TerminalPaintTally.reportEveryMs)?.count == 10)
    }

    @Test func aMarkNeverPaintedIsDroppedNotKeptForever() {
        var tally = TerminalPaintTally()
        tally.handed(10)
        tally.mark(seq: 1, receivedMs: 0)
        tally.presented(parsed: 0, atMs: TerminalPaintTally.maxWaitMs + 1)
        #expect(tally.dropped == 1)
        #expect(tally.pending.isEmpty)
        for seq in 0...TerminalPaintTally.maxMarks { tally.handed(1); tally.mark(seq: seq + 2, receivedMs: 1) }
        #expect(tally.dropped == 2)
        tally.reset()
        #expect(tally.handed == 0)
    }

    @Test func theReportLineIsWhatHostdReads() throws {
        let line = try #require(TerminalPaintReport(program: "claude", samples: [[1, 2, 3]], clock: [[1, 2, 3, 4]], rttMs: 5).line())
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["kind"] as? String == "paint")
        #expect(object["samples"] as? [[Double]] == [[1, 2, 3]])
        #expect(object["clock"] as? [[Double]] == [[1, 2, 3, 4]])
        #expect(object["rtt_ms"] as? Int == 5)
        let answer = Data(#"{"kind":"clock","t0":10,"t1":20.5,"t2":21}"#.utf8)
        #expect(TerminalPaintReport.clockSample(answer: answer, t3: 30) == [10, 20.5, 21, 30])
        #expect(TerminalPaintReport.clockSample(answer: Data("{}".utf8), t3: 1) == nil)
    }
}

import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The frame times of one terminal pan, as the phone sends them to the Mac (`phone-frames`).
@Suite struct TerminalPanFramesTests {
    @Test func tallyCountsIntervalsAndTheShortestNominal() {
        var tally = TerminalPanFrameTally()
        var t = 100.0
        // The first tick only starts the clock.
        let started = tally.tick(timestamp: t, nominal: 1.0 / 120)
        #expect(!started)
        for interval in [1.0 / 120, 1.0 / 120, 1.0 / 40, 1.0 / 120] {
            t += interval
            let full = tally.tick(timestamp: t, nominal: interval < 0.01 ? 1.0 / 120 : 1.0 / 60)
            #expect(!full)
        }
        tally.rows = 5000
        tally.output(1200)
        tally.output(800)
        let pan = tally.take(.tui)
        #expect(pan.kind == .tui)
        #expect(pan.rows == 5000)
        #expect(pan.bytesIn == 2000)
        #expect(pan.intervalsMs == [8.33, 8.33, 25, 8.33])
        #expect(pan.expectedMs == 8.33)
        #expect(tally.intervalsMs.isEmpty)
        // The next pan starts clean: no interval across the gap between pans.
        let restarted = tally.tick(timestamp: t + 5, nominal: 1.0 / 60)
        #expect(!restarted)
        let second = tally.tick(timestamp: t + 5 + 1.0 / 60, nominal: 1.0 / 60)
        #expect(!second)
        let next = tally.take(.scrollback)
        #expect(next.intervalsMs == [16.67])
        #expect(next.rows == nil)
        #expect(next.bytesIn == 0)
        #expect(next.expectedMs == 16.67)
    }

    @Test func tallyStopsAtTheCap() {
        var tally = TerminalPanFrameTally()
        var full = false
        for i in 0...(TerminalPanFrames.maxFrames + 10) where !full {
            full = tally.tick(timestamp: Double(i) / 120, nominal: 1.0 / 120)
        }
        #expect(full)
        #expect(tally.intervalsMs.count == TerminalPanFrames.maxFrames)
        #expect(tally.take(.tui).intervalsMs.count == TerminalPanFrames.maxFrames)
    }

    @Test func lineIsTheWireShape() throws {
        let pan = TerminalPanFrames(kind: .scrollback, program: "zsh", app: "1.0 (7)", expectedMs: 16.6666, intervalsMs: [16.6666, 16.7, 33.3, 16.6],
                                    rows: 12000, bytesIn: 4096, rttMs: 42)
        let line = try #require(pan.line())
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["kind"] as? String == "scrollback")
        #expect(object["program"] as? String == "zsh")
        #expect(object["app"] as? String == "1.0 (7)")
        #expect(object["expected_ms"] as? Double == 16.67)
        #expect(object["intervals_ms"] as? [Double] == [16.67, 16.7, 33.3, 16.6])
        #expect(object["rows"] as? Int == 12000)
        #expect(object["bytes_in"] as? Int == 4096)
        #expect(object["rtt_ms"] as? Int == 42)
        #expect(!String(decoding: line, as: UTF8.self).contains("\n"), "one line")
    }

    @Test func tooShortOrRatelessPansSendNothing() {
        #expect(TerminalPanFrames(kind: .tui, expectedMs: 8.33, intervalsMs: [8.33, 8.33]).line() == nil)
        #expect(TerminalPanFrames(kind: .tui, expectedMs: 0, intervalsMs: Array(repeating: 8.33, count: 10)).line() == nil)
    }
}

import Foundation
import Testing
@testable import CmuxNextWakeups

@Suite struct TypingLatencyProbeTests {
    private func rows(_ path: String) throws -> [[String: String]] {
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return lines.dropFirst().map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("typing-probe-\(UUID().uuidString).csv").path
    }

    @Test func disabledWithoutPathWritesNothing() {
        let probe = TypingLatencyProbe(path: nil)
        probe.keyDown(eventTimestamp: 1)
        probe.mark(.contents)
        probe.flush()
    }

    @Test func aKeyThroughEveryHopWritesOneCompleteRow() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = TypingLatencyProbe(path: path)
        probe.keyDown(eventTimestamp: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9)
        for mark in TypingLatencyProbe.Mark.allCases where mark != .dispatchStart { probe.mark(mark) }
        probe.flush()
        let rows = try rows(path)
        #expect(rows.count == 1)
        #expect(rows[0]["complete"] == "1")
        for mark in TypingLatencyProbe.Mark.allCases {
            let value = try #require(Double(rows[0][mark.columnName] ?? ""))
            #expect(value >= 0)
        }
    }

    /// Output decoded before this key's input reached the socket is an
    /// earlier key's echo and must not be taken for this key's.
    @Test func outputBeforeTheInputIsIgnored() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = TypingLatencyProbe(path: path)
        probe.keyDown(eventTimestamp: 0)
        probe.mark(.outputDecoded)
        probe.mark(.outputMain)
        probe.mark(.outputParsed)
        probe.mark(.contents)
        // The next key closes the open sample unfinished.
        probe.keyDown(eventTimestamp: 0)
        probe.flush()
        let rows = try rows(path)
        #expect(rows.count == 1)
        #expect(rows[0]["complete"] == "0")
        #expect(rows[0]["output_decoded_ms"] == "")
        #expect(rows[0]["contents_ms"] == "")
    }
}

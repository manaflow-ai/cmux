import Foundation
import Testing
@testable import CmuxNextWakeups

/// A key press's echo counts only for the terminal that sent the key (scripts/cmux-next/trace.py key-press
/// flows): output of a busy neighbor terminal never closes the press, and only the sending attachment gets
/// the press's flow id.
@Suite struct TypingLatencyProbeSourceTests {
    private final class Token {}

    /// The CSV rows the probe wrote after its header (index, complete, ...).
    private func rows(_ path: String, _ probe: TypingLatencyProbe) throws -> [[String]] {
        probe.flush()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private func csvPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("typing-probe-\(UUID().uuidString).csv").path
    }

    @Test func aBusyNeighborsEchoDoesNotCloseThePress() throws {
        let path = csvPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = TypingLatencyProbe(path: path)
        let laneA = Token(), layerA = Token(), laneB = Token(), layerB = Token()
        probe.keyDown(eventTimestamp: 0)
        probe.mark(.ioWrite)
        probe.mark(.socketSubmit, source: .terminal(1))
        // Terminal 2 prints at the same time: its whole output path runs, and nothing of it counts.
        probe.mark(.outputDecoded, source: .terminal(2))
        probe.mark(.outputReceived, source: .terminal(2), next: .object(ObjectIdentifier(laneB)))
        probe.mark(.outputParsed, source: .object(ObjectIdentifier(laneB)), next: .object(ObjectIdentifier(layerB)))
        probe.mark(.contents, source: .object(ObjectIdentifier(layerB)))
        #expect(try rows(path, probe).isEmpty, "a neighbor's frame closed the press")
        // Terminal 1's echo closes it.
        probe.mark(.outputDecoded, source: .terminal(1))
        probe.mark(.outputReceived, source: .terminal(1), next: .object(ObjectIdentifier(laneA)))
        // Terminal 1's echo parsed on another lane, then a frame of another layer: neither counts.
        probe.mark(.outputParsed, source: .object(ObjectIdentifier(laneB)), next: .object(ObjectIdentifier(layerB)))
        probe.mark(.outputParsed, source: .object(ObjectIdentifier(laneA)), next: .object(ObjectIdentifier(layerA)))
        probe.mark(.contents, source: .object(ObjectIdentifier(layerB)))
        #expect(try rows(path, probe).isEmpty, "another layer's frame closed the press")
        probe.mark(.contents, source: .object(ObjectIdentifier(layerA)))
        let written = try rows(path, probe)
        try #require(written.count == 1)
        #expect(written[0][1] == "1", "the press is complete")
    }

    /// Each row names its key's own event time (`event_uptime_ns`, CLOCK_UPTIME_RAW nanoseconds), so a row can be
    /// joined to a HID post time, the main-thread watchdog's stalls (`debug.hangs` start_uptime_ns) and a screen
    /// recording's frame times (TYPING UNDER LOAD); the other columns are milliseconds after it.
    @Test func eachRowNamesItsKeysEventTime() throws {
        let path = csvPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = TypingLatencyProbe(path: path)
        let lane = Token(), layer = Token()
        probe.keyDown(eventTimestamp: 1234.5)
        probe.mark(.ioWrite)
        probe.mark(.socketSubmit, source: .terminal(1))
        probe.mark(.outputDecoded, source: .terminal(1))
        probe.mark(.outputReceived, source: .terminal(1), next: .object(ObjectIdentifier(lane)))
        probe.mark(.outputParsed, source: .object(ObjectIdentifier(lane)), next: .object(ObjectIdentifier(layer)))
        probe.mark(.contents, source: .object(ObjectIdentifier(layer)))
        probe.flush()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: ",").map(String.init)
        let column = try #require(header.firstIndex(of: "event_uptime_ns"), "no event_uptime_ns column: \(header)")
        let row = try #require(try rows(path, probe).first)
        #expect(row[column] == "1234500000000")
    }

    @Test func onlyTheSendingTerminalGetsTheFlow() {
        let probe = TypingLatencyProbe(path: nil, flows: true)
        probe.keyDown(eventTimestamp: 0)
        let flow = probe.openFlow(for: .terminal(1))
        #expect(flow != nil)
        probe.mark(.ioWrite)
        probe.mark(.socketSubmit, source: .terminal(1))
        #expect(probe.openFlow(for: .terminal(1)) == flow)
        #expect(probe.openFlow(for: .terminal(2)) == nil, "a neighbor's input took the press's flow")
    }
}

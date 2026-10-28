import Foundation
import Testing
@testable import CmuxNextWakeups

/// A key press's echo counts only for the terminal that sent the key (scripts/cmux-next/trace.py key-press
/// flows): output of a busy neighbor terminal never closes the press, and only the sending terminal's input
/// gets the press's flow id. The probe attributes each hop to its terminal by its surface key
/// (``TypingLatencyProbe/SurfaceKey``) and each echo chunk to the press the daemon names (its flow).
@Suite struct TypingLatencyProbeSourceTests {
    /// The CSV rows the probe wrote after its header (index, complete, ...).
    private func rows(_ path: String, _ probe: TypingLatencyProbe) throws -> [[String]] {
        probe.flush()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private func csvPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("typing-probe-\(UUID().uuidString).csv").path
    }

    /// One key-down the router hands to the terminal `surface`, which Ghostty takes.
    private func dispatch(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceKey) {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(surface)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
    }

    @Test func aBusyNeighborsEchoDoesNotCloseThePress() throws {
        let path = csvPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = TypingLatencyProbe(path: path)
        let typed = probe.makeSurfaceKey(), neighbor = probe.makeSurfaceKey()
        dispatch(probe, on: typed)
        probe.inputWritten(on: typed)
        let flow = try #require(probe.openFlow, "the written press has no flow for its send")
        probe.mark(.socketSubmit, flow: flow)
        // Terminal 2 prints at the same time: its whole output path runs, and nothing of it counts.
        probe.mark(.outputReceived, surface: neighbor)
        probe.mark(.outputParsed, surface: neighbor)
        probe.mark(.contents, surface: neighbor)
        #expect(try rows(path, probe).isEmpty, "a neighbor's frame closed the press")
        // Terminal 1's echo, named by the daemon, is decoded, received and parsed for its own press.
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        // A frame of the neighbor's layer still does not count.
        probe.mark(.contents, surface: neighbor)
        #expect(try rows(path, probe).isEmpty, "another layer's frame closed the press")
        // Terminal 1's frame closes it.
        probe.mark(.contents, surface: typed)
        let written = try rows(path, probe)
        try #require(written.count == 1)
        #expect(written[0][1] == "1", "the press is complete")
    }

    @Test func onlyTheSendingTerminalGetsTheFlow() {
        let probe = TypingLatencyProbe(path: nil)
        probe.startFlows()
        defer { probe.stopFlows() }
        let typed = probe.makeSurfaceKey(), neighbor = probe.makeSurfaceKey()
        dispatch(probe, on: typed)
        // A neighbor's input is written first: it is not the press's, so no send takes the press's flow.
        probe.inputWritten(on: neighbor)
        #expect(probe.openFlow == nil, "a neighbor's input took the press's flow")
        probe.inputWritten(on: typed)
        let flow = probe.openFlow
        #expect(flow != nil, "the sending terminal's write did not get the press's flow")
        if let flow { probe.mark(.socketSubmit, flow: flow) }
        #expect(probe.openFlow == nil, "a sent press kept its flow for the next send")
    }
}

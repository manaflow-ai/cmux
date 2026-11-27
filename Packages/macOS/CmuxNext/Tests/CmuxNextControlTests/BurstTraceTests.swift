#if DEBUG
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `debug.burst` (``BurstTrace``): marks only while armed, a press's marks keyed by its key event, and
/// a terminal's first output counted only after the daemon echoed a grid this view sent, so output
/// already on its way before the resize is never taken for the TUI's redraw.
@Suite struct BurstTraceTests {
    private func kinds(_ reply: JSONValue) -> [String] {
        (reply["events"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
    }

    @Test("A mark before start or after stop records nothing")
    func disarmedRecordsNothing() {
        let trace = BurstTrace()
        trace.mark(.refusal, input: 1)
        trace.closed(tabs: ["a"], emptiesPane: false, input: 1)
        trace.gridSent(surface: 1, cols: 80, rows: 24, expectsEcho: true)
        trace.gridAnnounced(surface: 1, cols: 80, rows: 24)
        trace.output(surface: 1)
        #expect(!trace.isArmed)
        _ = trace.control(["action": .string("start")])
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply).isEmpty)
        trace.mark(.closeSwallowed, input: nil)
        _ = trace.control(["action": .string("start")])
        #expect(kinds(trace.control(["action": .string("stop")])).isEmpty)
    }

    @Test("The first output counts only after the stream echoed a grid this view sent")
    func firstOutputAfterEachEcho() {
        let trace = BurstTrace()
        _ = trace.control(["action": .string("start")])
        trace.output(surface: 7)  // no grid yet: not a first output
        trace.gridSent(surface: 7, cols: 100, rows: 30, expectsEcho: true)
        trace.output(surface: 7)  // on its way before the daemon applied the grid: not the redraw
        trace.gridAnnounced(surface: 7, cols: 120, rows: 30)  // another client's grid: no echo
        trace.output(surface: 7)
        trace.gridAnnounced(surface: 7, cols: 100, rows: 30)  // the echo
        trace.output(surface: 8)  // another terminal's output
        trace.output(surface: 7)
        trace.output(surface: 7)
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply) == ["pty_grid", "grid_echo", "first_output"])
        #expect(reply["counts"]?["first_output"]?.intValue == 1)
        #expect(reply["dropped"]?.intValue == 0)
    }

    @Test("An echo of a later grid also settles the earlier ones the stream skipped")
    func echoSettlesEarlierGrids() {
        let trace = BurstTrace()
        _ = trace.control(["action": .string("start")])
        trace.gridSent(surface: 7, cols: 100, rows: 30, expectsEcho: true)
        trace.gridSent(surface: 7, cols: 90, rows: 30, expectsEcho: true)
        trace.gridAnnounced(surface: 7, cols: 90, rows: 30)
        trace.gridAnnounced(surface: 7, cols: 100, rows: 30)  // settled by the later echo: not an echo now
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply) == ["pty_grid", "pty_grid", "grid_echo"])
    }

    @Test("A grid the PTY already has is never echoed, so no echo or redraw is looked for")
    func unechoedGridIsNotAwaited() {
        let trace = BurstTrace()
        _ = trace.control(["action": .string("start")])
        trace.gridSent(surface: 7, cols: 100, rows: 30, expectsEcho: false)
        trace.gridAnnounced(surface: 7, cols: 100, rows: 30)  // an announce of it: not this view's echo
        #expect(trace.awaitingOutputCount == 0)
        trace.gridSent(surface: 8, cols: 90, rows: 30, expectsEcho: true)
        trace.gridAnnounced(surface: 8, cols: 90, rows: 30)
        #expect(trace.awaitingOutputCount == 1)
        let status = trace.control(["action": .string("status")], facts: ["resize_idle": .bool(true)])
        #expect(status["awaiting_output_surfaces"]?.intValue == 1 && status["resize_idle"]?.boolValue == true)
        trace.output(surface: 8)
        #expect(trace.awaitingOutputCount == 0)
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply) == ["pty_grid", "pty_grid", "grid_echo", "first_output"])
        #expect((reply["events"]?.arrayValue ?? []).prefix(2).map { $0["expects_echo"]?.boolValue } == [false, true])
    }

    @Test("Each press's marks carry its key event's timestamp, and a close its tabs")
    func pressMarksAreKeyed() {
        let trace = BurstTrace()
        _ = trace.control(["action": .string("start")])
        trace.mark(.closeSwallowed, input: 10.5)
        trace.mark(.creationCancelled, input: 10.6)
        trace.mark(.refusal, input: nil)
        trace.closed(tabs: ["tab_1", "tab_2"], emptiesPane: true, input: 10.7)
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply) == ["close_swallowed", "creation_cancelled", "refusal", "closed"])
        let events = reply["events"]?.arrayValue ?? []
        #expect(events.map { $0["event_s"]?.doubleValue } == [10.5, 10.6, nil, 10.7])
        #expect(events.last?["tabs"]?.arrayValue?.compactMap(\.stringValue) == ["tab_1", "tab_2"])
        #expect(events.last?["empties_pane"]?.boolValue == true)
    }
}
#endif

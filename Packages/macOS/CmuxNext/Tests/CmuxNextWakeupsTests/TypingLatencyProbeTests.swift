import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextWakeups

/// Key flows start at run time, each press in flight gets its own chain, a write and a send go to their
/// surface's oldest pending press, an echo marks only the press it names and only its own chunk, and a
/// surface's frame marks only the presses on it.
struct TypingLatencyProbeTests {
    /// Every `key.flow` hop a probe emits, in order.
    private final class Hops: Sendable {
        private let hops = Mutex<[(hop: String, flow: UInt64)]>([])

        func record(_ hop: String, _ flow: UInt64) {
            hops.withLock { $0.append((hop, flow)) }
        }

        /// The hops of `flow`, without the run-loop commits (the main run loop may turn during a test).
        func chain(_ flow: UInt64) -> [String] {
            hops.withLock { hops in
                hops.filter { $0.flow == flow && !$0.hop.hasSuffix(".commit") }.map(\.hop)
            }
        }

        var count: Int { hops.withLock { $0.count } }
    }

    private static let fullChain = ["app.key.dispatch", "app.key.terminal", "app.key.dispatched", "app.io_write", "app.send",
                                    "app.output.decoded", "app.output.received", "app.output.parsed", "app.frame.contents"]
    /// Up to the send: the press is in flight.
    private static let sentChain = Array(fullChain.prefix(5))

    /// The flow id of a probe's `index`th key-down.
    private func flow(_ index: Int) -> UInt64 {
        UInt64(UInt32(truncatingIfNeeded: getpid())) << 32 | UInt64(index)
    }

    /// One key-down dispatched to the terminal `surface`; `took`: Ghostty took it, so its bytes follow.
    private func dispatch(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceKey, took: Bool = true) {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(surface)
        if took { probe.terminalTookKey() }
        probe.mark(.dispatchEnd)
    }

    /// Ghostty's write on `surface` and the session's send of it; returns the flow the send carried.
    private func writeAndSend(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.inputWritten(on: surface)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        return flow
    }

    /// One key press dispatched to `surface` up to its `send`; returns the flow the send carried.
    private func press(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        dispatch(probe, on: surface)
        return try writeAndSend(probe, on: surface)
    }

    /// The echo of `flow` on `surface`, as the pipeline runs it: the decode names the press, the
    /// session and the lane mark the chunk that carries it, the frame marks the surface.
    private func echo(_ probe: TypingLatencyProbe, _ flow: UInt64, on surface: TypingLatencyProbe.SurfaceKey) {
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        probe.mark(.contents, surface: surface)
    }

    /// An echo from a daemon without exact flows: nothing names the press.
    private func flowlessEcho(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceKey) {
        probe.outputDecoded(flow: nil)
        probe.mark(.outputReceived, surface: surface)
        probe.mark(.outputParsed, surface: surface)
        probe.mark(.contents, surface: surface)
    }

    /// The CSV rows written so far: (index, complete).
    private func csvRows(_ probe: TypingLatencyProbe, at csv: URL) throws -> [(index: Int, complete: Bool)] {
        probe.flush()
        return try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").dropFirst().map { row in
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            return (Int(fields[0]) ?? -1, fields[1] == "1")
        }
    }

    private func temporaryCSV() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "typing-probe-\(UUID().uuidString).csv")
    }

    @Test func flowsStartAndStopAtRunTime() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        let surface = probe.makeSurfaceKey()
        #expect(!probe.isRecording)
        dispatch(probe, on: surface)
        probe.inputWritten(on: surface)
        #expect(probe.openFlow == nil)
        #expect(hops.count == 0)

        probe.startFlows()
        #expect(probe.isRecording)
        let flow = try press(probe, on: surface)
        #expect(flow >> 32 == UInt64(UInt32(truncatingIfNeeded: getpid())))
        #expect(hops.chain(flow) == Self.sentChain)

        probe.stopFlows()
        #expect(!probe.isRecording)
        dispatch(probe, on: surface)
        probe.inputWritten(on: surface)
        #expect(probe.openFlow == nil)
    }

    @Test func theLaunchDefaultStartsFlowsOnlyWhenSet() {
        let unset = TypingLatencyProbe(path: nil)
        unset.startFlows(launchEnvironment: [:])
        unset.startFlows(launchEnvironment: [TypingLatencyProbe.flowsEnvironmentKey: ""])
        #expect(!unset.flowsStarted)
        let set = TypingLatencyProbe(path: nil)
        set.startFlows(launchEnvironment: [TypingLatencyProbe.flowsEnvironmentKey: "/tmp/flows"])
        #expect(set.flowsStarted)
    }

    @Test func threeKeysBeforeAnyEchoGiveThreeChains() throws {
        let hops = Hops()
        let csv = temporaryCSV()
        defer { try? FileManager.default.removeItem(at: csv) }
        let probe = TypingLatencyProbe(path: csv.path, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        let flows = try (0..<3).map { _ in try press(probe, on: surface) }
        #expect(flows == [flow(0), flow(1), flow(2)])
        for flow in flows { echo(probe, flow, on: surface) }
        for flow in flows { #expect(hops.chain(flow) == Self.fullChain) }
        let rows = try csvRows(probe, at: csv)
        #expect(rows.map { $0.index } == [0, 1, 2])
        #expect(rows.allSatisfy { $0.complete })
    }

    /// The attach reader decodes every echo before the session takes the first chunk: each chunk's
    /// received and parsed hops go to its own press, and a frame closes only presses whose chunk parsed.
    @Test func echoesDecodedAheadMarkOnlyTheirOwnChunk() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        let flows = try (0..<3).map { _ in try press(probe, on: surface) }
        for flow in flows { probe.outputDecoded(flow: flow) }
        let decoded = Self.sentChain + ["app.output.decoded"]
        for (done, flow) in flows.enumerated() {
            probe.mark(.outputReceived, flow: flow)
            probe.mark(.outputParsed, flow: flow)
            probe.mark(.contents, surface: surface)
            for earlier in flows[...done] { #expect(hops.chain(earlier) == Self.fullChain) }
            for later in flows[(done + 1)...] { #expect(hops.chain(later) == decoded) }
        }
    }

    @Test func anEchoMarksOnlyThePressItNames() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        let first = try press(probe, on: surface), second = try press(probe, on: surface)
        echo(probe, second, on: surface)
        #expect(hops.chain(second) == Self.fullChain)
        #expect(hops.chain(first) == Self.sentChain)
        echo(probe, first, on: surface)
        #expect(hops.chain(first) == Self.fullChain)
    }

    @Test func outputOnAnotherSurfaceMarksNothing() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let typed = probe.makeSurfaceKey(), other = probe.makeSurfaceKey()
        let exact = try press(probe, on: typed)
        echo(probe, exact, on: other)
        #expect(hops.chain(exact) == Array(Self.fullChain.dropLast()))
    }

    /// A daemon without exact flows: the decode takes the press, but another surface's chunks and frame
    /// do not.
    @Test func flowlessOutputOnAnotherSurfaceMarksNothing() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let typed = probe.makeSurfaceKey(), other = probe.makeSurfaceKey()
        let pressed = try press(probe, on: typed)
        flowlessEcho(probe, on: other)
        #expect(hops.chain(pressed) == Self.sentChain + ["app.output.decoded"])
        flowlessEcho(probe, on: typed)
        #expect(hops.chain(pressed) == Self.fullChain)
    }

    /// Key A then key B dispatch before Ghostty's IO thread writes A's bytes: the write, the send's flow
    /// and the send mark go to A, then to B, never to the newest press first.
    @Test func writesAndSendsGoToTheOldestPendingPress() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        dispatch(probe, on: surface)
        dispatch(probe, on: surface)
        #expect(probe.openFlow == nil)
        #expect(try writeAndSend(probe, on: surface) == flow(0))
        #expect(hops.chain(flow(0)) == Self.sentChain)
        #expect(hops.chain(flow(1)) == Array(Self.sentChain.prefix(3)))
        #expect(try writeAndSend(probe, on: surface) == flow(1))
        #expect(hops.chain(flow(1)) == Self.sentChain)
        #expect(probe.openFlow == nil)
    }

    /// A key the terminal saw but Ghostty did not take writes nothing, so the next key's write is not its.
    @Test func aKeyGhosttyDidNotTakeLeavesTheWriteToTheNext() throws {
        let probe = TypingLatencyProbe(path: nil)
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        dispatch(probe, on: surface, took: false)
        dispatch(probe, on: surface)
        #expect(try writeAndSend(probe, on: surface) == flow(1))
    }

    @Test func aWriteOnAnotherSurfaceMarksNothing() {
        let probe = TypingLatencyProbe(path: nil)
        probe.startFlows()
        let typed = probe.makeSurfaceKey(), other = probe.makeSurfaceKey()
        #expect(typed != other)
        dispatch(probe, on: typed)
        probe.inputWritten(on: other)
        #expect(probe.openFlow == nil)
    }

    /// A CSV alone (no key flows) still stamps the send, so the daemon's echo names its press.
    @Test func aCSVAloneStampsTheSend() throws {
        let csv = temporaryCSV()
        defer { try? FileManager.default.removeItem(at: csv) }
        let probe = TypingLatencyProbe(path: csv.path)
        #expect(!probe.flowsStarted)
        let surface = probe.makeSurfaceKey()
        let flow = try press(probe, on: surface)
        echo(probe, flow, on: surface)
        #expect(try csvRows(probe, at: csv).map { $0.complete } == [true])
    }

    /// A key that gets no echo (a password prompt) never takes the next key's: with a daemon that
    /// names no press, the next echo goes to the newest press sent and closes the silent one unfinished.
    @Test func aPressWithNoEchoDoesNotTakeTheNextOne() throws {
        let csv = temporaryCSV()
        defer { try? FileManager.default.removeItem(at: csv) }
        let probe = TypingLatencyProbe(path: csv.path)
        let surface = probe.makeSurfaceKey()
        _ = try press(probe, on: surface)  // silent
        _ = try press(probe, on: surface)
        flowlessEcho(probe, on: surface)
        let rows = try csvRows(probe, at: csv)
        #expect(rows.map { $0.index } == [0, 1])
        #expect(rows.map { $0.complete } == [false, true])
    }

    /// Once an echo named its press, an output that names none is other output, not an echo.
    @Test func anExactEchoTurnsTheFallbackOff() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        let echoed = try press(probe, on: surface)
        echo(probe, echoed, on: surface)
        let pending = try press(probe, on: surface)
        flowlessEcho(probe, on: surface)
        #expect(hops.chain(pending) == Self.sentChain)
    }

    /// One surface keeps every press the probe keeps: past ``TypingLatencyProbe/openCapacity`` only the
    /// oldest closes, and every other press still gets its full chain.
    @Test func aSurfaceKeepsEveryPressUpToTheCapacity() throws {
        let hops = Hops()
        let csv = temporaryCSV()
        defer { try? FileManager.default.removeItem(at: csv) }
        let probe = TypingLatencyProbe(path: csv.path, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = probe.makeSurfaceKey()
        let flows = try (0...TypingLatencyProbe.openCapacity).map { _ in try press(probe, on: surface) }
        for flow in flows { echo(probe, flow, on: surface) }
        #expect(hops.chain(flows[0]) == Self.sentChain)
        for flow in flows.dropFirst() { #expect(hops.chain(flow) == Self.fullChain) }
        let rows = try csvRows(probe, at: csv)
        #expect(rows.count == flows.count)
        #expect(rows.filter { !$0.complete }.map { $0.index } == [0])
    }
}

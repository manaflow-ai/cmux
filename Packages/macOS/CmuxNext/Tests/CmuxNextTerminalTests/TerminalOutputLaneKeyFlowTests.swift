import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Dispatch
import Foundation
import GhosttyNextKit
import Testing

/// A surface's output lane marks a key press's received and parsed hops on the chunk that carries its
/// echo, never on an earlier chunk, and marks only its own surface's presses. The
/// lane's parse is the test's recorder, so no Ghostty surface is made.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneKeyFlowTests {
    static var surface: ghostty_surface_t { unsafeBitCast(UInt(0x1000), to: ghostty_surface_t.self) }

    /// One key press on `key`, dispatched, written and sent; returns its flow.
    private func press(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(key)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: key)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        return flow
    }

    /// The attach reader decoded both echoes before the session took the first chunk: the lane marks
    /// each press parsed only once its own chunk parsed, so the frame after the first chunk closes only
    /// the first press.
    @Test func aChunkMarksOnlyThePressWhoseEchoItCarries() async throws {
        let hops = HopLog()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let key = probe.makeSurfaceKey()
        let gate = DispatchSemaphore(value: 0)
        let (parsedChunks, parsed) = AsyncStream.makeStream(of: Data.self)
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.key-flows", keyFlows: key, probe: probe) { _, data in
            parsed.yield(data)
            if data == Data("b".utf8) { gate.wait() }  // holds the lane inside the second chunk's parse
        }
        defer { lane.close() }
        let first = try press(probe, on: key), second = try press(probe, on: key)
        probe.outputDecoded(flow: first)
        probe.outputDecoded(flow: second)

        #expect(await lane.takeOffMain(.output(Data("a".utf8))))
        #expect(await lane.takeOffMain(.inputEcho(flow: first)))
        #expect(await lane.takeOffMain(.output(Data("b".utf8))))
        #expect(await lane.takeOffMain(.inputEcho(flow: second)))
        var iterator = parsedChunks.makeAsyncIterator()
        #expect(await iterator.next() == Data("a".utf8))
        #expect(await iterator.next() == Data("b".utf8))

        #expect(hops.has("app.output.received", first) && hops.has("app.output.received", second))
        #expect(hops.has("app.output.parsed", first))
        #expect(!hops.has("app.output.parsed", second), "the second press was marked parsed on the first chunk")
        probe.mark(.contents, surface: key)
        #expect(hops.has("app.frame.contents", first))
        #expect(!hops.has("app.frame.contents", second))

        gate.signal()
        await lane.drained()
        #expect(hops.has("app.output.parsed", second))
        probe.mark(.contents, surface: key)
        #expect(hops.has("app.frame.contents", second))
    }

    /// With a daemon that names no press, the lane's chunks mark the decoded presses on its own surface
    /// and none on another.
    @Test func aLaneMarksOnlyItsOwnSurface() async throws {
        let hops = HopLog()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let key = probe.makeSurfaceKey(), other = probe.makeSurfaceKey()
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.key-flows-other", keyFlows: key, probe: probe) { _, _ in }
        defer { lane.close() }
        let elsewhere = try press(probe, on: other)
        probe.outputDecoded(flow: nil)

        #expect(await lane.takeOffMain(.output(Data("x".utf8))))
        await lane.drained()
        #expect(hops.has("app.output.decoded", elsewhere))
        #expect(!hops.has("app.output.received", elsewhere))
        #expect(!hops.has("app.output.parsed", elsewhere))

        let here = try press(probe, on: key)
        probe.outputDecoded(flow: nil)
        #expect(await lane.takeOffMain(.output(Data("y".utf8))))
        await lane.drained()
        #expect(hops.has("app.output.parsed", here))
        #expect(!hops.has("app.output.received", elsewhere))
    }

    /// Any other event is the session's to handle on the main actor.
    @Test func otherEventsStayWithTheSession() async {
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.key-flows-events") { _, _ in }
        defer { lane.close() }
        #expect(await !lane.takeOffMain(.exited))
        #expect(await !lane.takeOffMain(.resize(cols: 80, rows: 24)))
    }
}

/// Every `key.flow` hop a probe emitted.
private nonisolated final class HopLog: Sendable {
    private let hops = Mutex<[(hop: String, flow: UInt64)]>([])

    func record(_ hop: String, _ flow: UInt64) {
        hops.withLock { $0.append((hop, flow)) }
    }

    func has(_ hop: String, _ flow: UInt64) -> Bool {
        hops.withLock { hops in hops.contains { $0.hop == hop && $0.flow == flow } }
    }
}

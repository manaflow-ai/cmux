import Foundation
import Testing
import CmuxNextCompat
@testable import CmuxNextAgentPane

/// The inbound pass of one agent pane over a streaming turn, through the socket's own entry (`receiveLocalReply`,
/// the same `arrived` -> `process` the WebSocket feeds), until the page queue holds every frame. Prints the CPU time per
/// 1,000 frames for the PR's table; the same file measures base and head (`scripts/measure/swift-test-bench.sh` with
/// `restore_from`).
///
/// Leo's NIGHTLY, 2026-11-21: the agent panes' inbound queues were about two thirds `StringProtocol.contains` in the
/// page-wait check, which scanned each `session/update` in full three times.
struct AcpmuxPaneInboundScanBench {
    /// A streaming turn's frames: agent chunks of `bytes` (non-ASCII, as a transcript has), every tenth an
    /// `_acpmux/event` record, the last one the turn's end.
    static func turn(frames: Int, bytes: Int) -> [String] {
        (0..<frames).map { index in
            if index == frames - 1 {
                return #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(index),"kind":"turn_end","stopReason":"end_turn"}}"#
            }
            if index % 10 == 9 {
                let text = String(repeating: "tool output — “line” ✓ \(index)\\n", count: max(1, bytes / 40))
                return #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(index),"kind":"tool_call_update","content":{"text":""# + text + #""}}}"#
            }
            return AcpmuxPaneInboundNativeTests.chunk(bytes: bytes, index: index)
        }
    }

    static func cpuTime() -> Duration {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let micros = Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
            + Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
        return .microseconds(micros)
    }

    /// One pass: every frame in through the socket, drained from the page queue as it fills. Returns the process CPU
    /// time and the wall time it took.
    @MainActor static func pass(_ frames: [String]) async -> (cpu: Duration, wall: Duration) {
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            limits: transport.limits,
            options: transport.permissionOptions,
            sessions: transport.sessions,
            ids: AcpmuxRequestIds(),
            signal: {})
        let cpu = cpuTime()
        let clock = ContinuousClock()
        let start = clock.now
        var taken = 0
        for (index, frame) in frames.enumerated() {
            socket.receiveLocalReply(frame)
            if index % 50 == 49 { taken += socket.take(maximumFrames: 10_000, maximumBytes: 1 << 30).frames.count }
        }
        let deadline = start.advanced(by: .seconds(60))
        while taken < frames.count, clock.now < deadline {
            let batch = socket.take(maximumFrames: 10_000, maximumBytes: 1 << 30)
            taken += batch.frames.count
            if batch.frames.isEmpty { try? await Task.sleep(for: .microseconds(200)) } // test: the inbound queue's pass
        }
        let wall = start.duration(to: clock.now)
        #expect(taken == frames.count, "the page got \(taken) of \(frames.count) frames")
        return (cpuTime() - cpu, wall)
    }

    @MainActor @Test(arguments: [2_048, 20_480])
    func inboundPassCPUPerThousandFrames(bytes: Int) async {
        // About 8 MB a pass: well under the page queue's 32 MB, so nothing is shed and every frame is scanned.
        let count = min(4_000, (8 << 20) / bytes)
        let frames = Self.turn(frames: count, bytes: bytes)
        _ = await Self.pass(Array(frames.prefix(200))) // warm up
        var runs: [(cpu: Duration, wall: Duration)] = []
        for _ in 0..<5 { runs.append(await Self.pass(frames)) }
        let cpu = runs.map(\.cpu).sorted()[runs.count / 2] * 1_000 / count
        let wall = runs.map(\.wall).sorted()[runs.count / 2] * 1_000 / count
        print("inbound scan bench, 1,000 frames of \(bytes) B: cpu \(cpu), wall \(wall) (median of 5)")
    }

    /// The scan's answers, so the faster path is the same check.
    @Test func pageWaitsOnTheTurnEndAndOnNoChunk() {
        let frames = Self.turn(frames: 20, bytes: 2_048)
        #expect(AcpmuxPaneSocket.pageWaits(on: frames[19]))
        #expect(!AcpmuxPaneSocket.pageWaits(on: frames[0]))
        #expect(!AcpmuxPaneSocket.pageWaits(on: frames[9]))
        #expect(AcpmuxPaneSocket.pageWaits(on: #"{"method":"_acpmux/event","params":{"kind" : "queued"}}"#))
        #expect(AcpmuxPaneSocket.pageWaits(on: #"{"id":3,"method":"session/request_permission","params":{}}"#))
        #expect(!AcpmuxPaneSocket.pageWaits(on: #"{"method":"_acpmux/event","params":{"kind":"turn_endless"}}"#))
    }
}

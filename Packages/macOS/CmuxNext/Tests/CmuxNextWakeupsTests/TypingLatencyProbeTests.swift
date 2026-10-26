import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextWakeups

/// Key flows start at run time, each press in flight gets its own chain, and a surface's output hops mark
/// only the presses open on it whose echo the daemon named (p09-observability-019).
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

    /// One key press dispatched to the terminal `surface` up to its `send`; returns the flow the send carried.
    private func press(_ probe: TypingLatencyProbe, on surface: TypingLatencyProbe.SurfaceFlows) throws -> UInt64 {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(surface)
        probe.mark(.dispatchEnd)
        probe.mark(.ioWrite)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit)
        return flow
    }

    /// The echo of `flow` on `surface`: the decode names the press, the lane and the frame mark the surface.
    private func echo(_ probe: TypingLatencyProbe, _ flow: UInt64?, on surface: TypingLatencyProbe.SurfaceFlows) {
        probe.mark(.outputDecoded, flow: flow)
        probe.mark(.outputReceived, surface: surface)
        probe.mark(.outputParsed, surface: surface)
        probe.mark(.contents, surface: surface)
    }

    @Test func flowsStartAndStopAtRunTime() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        #expect(!probe.isRecording)
        probe.keyDown(eventTimestamp: 0)
        #expect(probe.openFlow == nil)
        #expect(hops.count == 0)

        probe.startFlows()
        #expect(probe.isRecording)
        let flow = try press(probe, on: TypingLatencyProbe.SurfaceFlows())
        #expect(flow >> 32 == UInt64(UInt32(truncatingIfNeeded: getpid())))
        #expect(hops.chain(flow) == Array(Self.fullChain.prefix(5)))

        probe.stopFlows()
        #expect(!probe.isRecording)
        probe.keyDown(eventTimestamp: 0)
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
        let csv = FileManager.default.temporaryDirectory.appending(path: "typing-probe-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csv) }
        let probe = TypingLatencyProbe(path: csv.path, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = TypingLatencyProbe.SurfaceFlows()
        let flows = try (0..<3).map { _ in try press(probe, on: surface) }
        #expect(Set(flows).count == 3)
        for flow in flows { echo(probe, flow, on: surface) }
        for flow in flows {
            #expect(hops.chain(flow) == Self.fullChain)
            #expect(!surface.contains(flow))
        }
        probe.flush()
        let rows = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n").dropFirst()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false)[1] == "1" })
    }

    @Test func anEchoMarksOnlyThePressItNames() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = TypingLatencyProbe.SurfaceFlows()
        let first = try press(probe, on: surface), second = try press(probe, on: surface)
        echo(probe, second, on: surface)
        #expect(hops.chain(second) == Self.fullChain)
        #expect(hops.chain(first) == Array(Self.fullChain.prefix(5)))
        #expect(surface.contains(first))
    }

    @Test func outputOnAnotherSurfaceMarksNothing() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let typed = TypingLatencyProbe.SurfaceFlows(), other = TypingLatencyProbe.SurfaceFlows()
        let flow = try press(probe, on: typed)
        echo(probe, flow, on: other)
        #expect(hops.chain(flow) == Array(Self.fullChain.prefix(6)))
    }

    @Test func anEchoWithoutAFlowGoesToTheOldestPress() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let surface = TypingLatencyProbe.SurfaceFlows()
        let first = try press(probe, on: surface), second = try press(probe, on: surface)
        echo(probe, nil, on: surface)
        #expect(hops.chain(first) == Self.fullChain)
        #expect(hops.chain(second) == Array(Self.fullChain.prefix(5)))
    }

    @Test func onlyThePressNotSentYetIsTheOpenFlow() throws {
        let probe = TypingLatencyProbe(path: nil)
        probe.startFlows()
        _ = try press(probe, on: TypingLatencyProbe.SurfaceFlows())
        #expect(probe.openFlow == nil)
    }

    @Test func aSurfaceKeepsItsNewestPresses() {
        let surface = TypingLatencyProbe.SurfaceFlows()
        let count = UInt64(TypingLatencyProbe.SurfaceFlows.capacity)
        for flow in 1...(count + 2) { surface.open(flow) }
        surface.open(count + 2)  // already open: no second slot
        #expect(!surface.contains(1) && !surface.contains(2))
        #expect((3...(count + 2)).allSatisfy(surface.contains))
        surface.close(5)
        #expect(!surface.contains(5))
    }

    @Test func aPressPastTheCapacityClosesTheOldest() throws {
        let hops = Hops()
        let probe = TypingLatencyProbe(path: nil, hopRecorder: { hops.record($0, $1) })
        probe.startFlows()
        let flows = try (0...TypingLatencyProbe.openCapacity).map { _ in try press(probe, on: TypingLatencyProbe.SurfaceFlows()) }
        probe.mark(.outputDecoded, flow: flows[0])
        #expect(!hops.chain(flows[0]).contains("app.output.decoded"))
        probe.mark(.outputDecoded, flow: flows[1])
        #expect(hops.chain(flows[1]).contains("app.output.decoded"))
    }
}

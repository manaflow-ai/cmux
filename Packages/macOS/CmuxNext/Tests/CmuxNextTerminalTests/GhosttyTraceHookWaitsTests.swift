import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Dispatch
import Testing

/// The trace hook's lock-free parts: a surface's GPU waits, where a handoff and a
/// GPU completion race from two threads and each flow goes to the presents exactly once, and the surface
/// table that finds a surface by `ghostty_surface_trace_id`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct GhosttyTraceHookWaitsTests {
    /// The flows the racing threads took, in the order they took them.
    nonisolated final class Delivered: Sendable {
        private let taken = Mutex<[UInt64]>([])

        func add(_ flows: [UInt64]) { taken.withLock { $0.append(contentsOf: flows) } }
        var flows: [UInt64] { taken.withLock { $0 } }
    }

    private static func surface() -> GhosttyTraceHook.Surface {
        GhosttyTraceHook.Surface(key: TypingLatencyProbe.SurfaceKey(id: 1, route: .local), echoStage: nil)
    }

    /// Flows past the free waits are delivered at once, never left waiting for a completion nobody gives them.
    @Test func flowsPastTheWaitsAreDeliveredAtOnce() {
        let surface = Self.surface()
        let capacity = GhosttyTraceHook.Surface.gpuWaitCapacity
        let flows = (1...UInt64(capacity + 3)).map { $0 << 8 }

        let now = surface.awaitGPU(flows, seq: 1)
        #expect(now == Array(flows.suffix(3)))
        #expect(surface.gpuDidFinish(seq: 1).sorted() == Array(flows.prefix(capacity)))
        #expect(surface.gpuDidFinish(seq: 2).isEmpty)
    }

    /// A completion takes the flows of its frame and of every earlier one, not a later frame's.
    @Test func aCompletionTakesItsFrameAndEarlierOnes() {
        let surface = Self.surface()
        #expect(surface.awaitGPU([0x10], seq: 1).isEmpty)
        #expect(surface.awaitGPU([0x20], seq: 2).isEmpty)
        #expect(surface.awaitGPU([0x30], seq: 3).isEmpty)
        #expect(surface.gpuDidFinish(seq: 2).sorted() == [0x10, 0x20])
        #expect(surface.gpuFinished(2) && !surface.gpuFinished(3))
        #expect(surface.gpuDidFinish(seq: 3) == [0x30])
    }

    /// A handoff on one thread and its frame's GPU completion on another, many times: every flow is delivered
    /// once, by one of the two, however their atomics interleave.
    @Test func aCompletionRacingAHandoffDeliversEachFlowOnce() {
        let rounds = 2_000
        let delivered = Delivered()
        for round in 1...rounds {
            let surface = Self.surface()
            let flow = UInt64(round)
            DispatchQueue.concurrentPerform(iterations: 2) { side in
                delivered.add(side == 0 ? surface.awaitGPU([flow], seq: 1) : surface.gpuDidFinish(seq: 1))
            }
        }
        let flows = delivered.flows
        #expect(flows.count == rounds, "each flow delivered exactly once")
        #expect(Set(flows).count == rounds)
    }

    /// Two completions racing for the same waits: each flow goes to one of them.
    @Test func racingCompletionsTakeEachFlowOnce() {
        let delivered = Delivered()
        for round in 0..<500 {
            let surface = Self.surface()
            let base = UInt64(round) << 8
            let flows = (1...UInt64(GhosttyTraceHook.Surface.gpuWaitCapacity)).map { base | $0 }
            #expect(surface.awaitGPU(flows, seq: 1).isEmpty)
            DispatchQueue.concurrentPerform(iterations: 2) { side in
                delivered.add(surface.gpuDidFinish(seq: UInt64(1 + side)))
            }
        }
        let flows = delivered.flows
        #expect(flows.count == 500 * GhosttyTraceHook.Surface.gpuWaitCapacity)
        #expect(Set(flows).count == flows.count)
    }

    @Test func theSurfaceTableFindsCollidingIdsPastARemovedOne() {
        let table = GhosttyTraceHook.SurfaceTable(capacity: 4)
        let a = Self.surface(), b = Self.surface(), c = Self.surface(), d = Self.surface()
        defer { withExtendedLifetime((a, b, c, d)) {} } // the table holds no reference
        // 1, 5 and 9 share a home slot.
        #expect(table.insert(a, id: 1) && table.insert(b, id: 5) && table.insert(c, id: 9))
        #expect(table.surface(5)?.takeUnretainedValue() === b)
        table.remove(id: 5)
        #expect(table.surface(5) == nil)
        #expect(table.surface(9)?.takeUnretainedValue() === c, "a lookup probes past a removed entry")
        #expect(table.insert(d, id: 13), "a removed entry is free again")
        #expect(table.surface(13)?.takeUnretainedValue() === d)
        #expect(table.insert(Self.surface(), id: 2))
        #expect(!table.insert(Self.surface(), id: 3), "four slots, four surfaces")
        #expect(table.surface(0) == nil && table.surface(77) == nil)
    }
}

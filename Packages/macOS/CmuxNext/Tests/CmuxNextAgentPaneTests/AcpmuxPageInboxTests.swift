import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page inbox (``AcpmuxPageInbox``) against the `Array` it replaced: the same random appends,
/// takes and clears give the same frames in the same order. Then the drain a page a full ceiling
/// behind does, in input-sized flushes, timed for both in one harness, with a budget and a 10x check.
/// Runs on every PR (no environment gate).
struct AcpmuxPageInboxTests {
    /// A small deterministic generator (SplitMix64), so a failure replays from its seed.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: 0..<24)
    func matchesTheArrayItReplaced(seed: Int) {
        var random = Seeded(state: UInt64(seed))
        var oracle: [String] = []
        var inbox = AcpmuxPageInbox()
        var next = 0
        for _ in 0..<4_000 {
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<45:
                let frames = (0..<Int.random(in: 1...300, using: &random)).map { _ in next += 1; return "f\(next)" }
                oracle.append(contentsOf: frames)
                inbox.append(contentsOf: frames)
            case 45..<60:
                next += 1
                oracle.append("f\(next)")
                inbox.append("f\(next)")
            case 60..<98:
                let k = Int.random(in: 0...min(oracle.count, 600), using: &random)
                let expected = Array(oracle.prefix(k))
                oracle.removeFirst(k)
                #expect(inbox.removeFirst(k) == expected, "seed \(seed)")
            default:
                oracle.removeAll()
                inbox.removeAll()
            }
            #expect(inbox.count == oracle.count, "seed \(seed)")
            #expect(inbox.isEmpty == oracle.isEmpty, "seed \(seed)")
            if !oracle.isEmpty {
                let offset = Int.random(in: 0..<oracle.count, using: &random)
                #expect(inbox[offset] == oracle[offset], "seed \(seed)")
            }
        }
    }

    /// The old take: `Array(prefix)` then `removeFirst(count)`.
    static func drainArray(_ frames: [String], flush: Int) -> Int {
        var queue = frames
        var taken = 0
        while !queue.isEmpty {
            let count = min(flush, queue.count)
            let batch = Array(queue.prefix(count))
            queue.removeFirst(count)
            taken += batch.count
        }
        return taken
    }

    static func drainInbox(_ frames: [String], flush: Int) -> Int {
        var queue = AcpmuxPageInbox()
        queue.append(contentsOf: frames)
        var taken = 0
        while !queue.isEmpty { taken += queue.removeFirst(min(flush, queue.count)).count }
        return taken
    }

    /// Best of `rounds` wall times, in milliseconds.
    static func best(rounds: Int = 5, _ body: () -> Int) -> Double {
        var best = Double.infinity
        for _ in 0..<rounds {
            let start = ContinuousClock.now
            _ = body()
            let elapsed = start.duration(to: .now)
            best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
        }
        return best
    }

    /// A page the ceiling behind (32,768 frames, ``AgentPaneTransport/Limits/ceilingQueuedFrames``), drained
    /// in the input-pending flush (64 frames): the most takes per backlog the host makes. Budget: 25 ms for
    /// the whole drain (it measures about 1 ms); 10x the backlog costs at most 20x (linear, with room for caches).
    @Test func drainsABacklogInLinearTime() {
        let flush = AgentPaneTransport.Limits().inputFramesPerFlush
        let big = (0..<32_768).map { #"{"jsonrpc":"2.0","method":"session/update","params":{"s":\#($0)}}"# }
        let small = Array(big.prefix(3_277))
        #expect(Self.drainInbox(big, flush: flush) == big.count)
        let inboxBig = Self.best { Self.drainInbox(big, flush: flush) }
        let inboxSmall = Self.best { Self.drainInbox(small, flush: flush) }
        let arrayBig = Self.best(rounds: 3) { Self.drainArray(big, flush: flush) }
        let arraySmall = Self.best(rounds: 3) { Self.drainArray(small, flush: flush) }
        print(String(format: "page inbox drain, %d-frame flushes: array %.2f ms @3,277 -> %.2f ms @32,768 (x%.1f); inbox %.2f ms @3,277 -> %.2f ms @32,768 (x%.1f)",
                     flush, arraySmall, arrayBig, arrayBig / max(arraySmall, 0.001), inboxSmall, inboxBig, inboxBig / max(inboxSmall, 0.001)))
        #expect(inboxBig < 25, "drain of 32,768 frames took \(inboxBig) ms, budget 25 ms")
        #expect(inboxBig < max(inboxSmall, 0.05) * 20, "10x the backlog cost \(inboxBig / inboxSmall)x, not linear")
    }
}

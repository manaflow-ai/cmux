import Foundation
import Testing
@testable import CmuxNextAgentList

/// `v2.pr06.host_chat_change` (rows/pr06.rs, measured: false: the Linux gate script cannot run it):
/// p95 from the socket's bytes to the page receiver for one settled row, with the handle on a chat
/// of 100,000 rows against one of 100. Rounds alternate, each side takes the same samples, and the
/// first round of each side is a warm-up that counts for neither.
@Suite("AcpmuxChatRowsBench", .serialized)
struct AcpmuxChatRowsBench {
    static let rounds = 10
    static let samplesPerRound = 100

    /// A host whose handle holds a 100-row window of a chat whose cursor is `rows`.
    private func side(rows: Int) async throws -> (fed: FedChatRowsHost, next: Int) {
        let fed = FedChatRowsHost()
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: rows, ids: (rows - 99)...rows), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds.count == 100 })
        return (fed, rows + 1)
    }

    /// One sample: the ns from handing the driver one settled row's bytes to the receiver's call.
    private func sample(_ fed: FedChatRowsHost, seq: Int) async throws -> UInt64 {
        let before = fed.receiver.arrivals.count
        let bytes = ChatWire.op(seq, text: "a settled row of the same size")
        let driver = try #require(await fed.driver())
        let start = DispatchTime.now().uptimeNanoseconds
        driver.feedForTesting(bytes)
        while fed.receiver.arrivals.count == before { try await Task.sleep(for: .microseconds(200)) }
        return fed.receiver.arrivals[before] - start
    }

    private static func p95(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }

    @Test("v2.pr06.host_chat_change: one settled row, a chat of 100,000 rows within 1.2x of one of 100")
    func hostChatChange() async throws {
        var small = try await side(rows: 100)
        var god = try await side(rows: 100_000)
        var smallSamples: [UInt64] = []
        var godSamples: [UInt64] = []
        var roundLines: [String] = []
        for round in 0..<Self.rounds {
            var s: [UInt64] = []
            var g: [UInt64] = []
            // Alternate which side goes first in a round, and the sides sample by sample.
            for index in 0..<Self.samplesPerRound {
                let smallFirst = (round + index) % 2 == 0
                if smallFirst { s.append(try await sample(small.fed, seq: small.next)) }
                g.append(try await sample(god.fed, seq: god.next))
                if !smallFirst { s.append(try await sample(small.fed, seq: small.next)) }
                small.next += 1
                god.next += 1
            }
            roundLines.append("round \(round): small p95 \(Self.p95(s)) ns, god p95 \(Self.p95(g)) ns")
            guard round > 0 else { continue }
            smallSamples += s
            godSamples += g
        }
        let smallP95 = Self.p95(smallSamples)
        let godP95 = Self.p95(godSamples)
        let ratio = Double(godP95) / Double(max(smallP95, 1))
        for line in roundLines { print("v2.pr06.host_chat_change \(line)") }
        print("{\"name\":\"v2.pr06.host_chat_change\",\"small_p95\":\(smallP95),\"god_p95\":\(godP95),\"unit\":\"ns\",\"samples\":\(smallSamples.count),\"ratio\":\(String(format: "%.3f", ratio))}")
        #expect(smallSamples.count == godSamples.count)
        #expect(small.fed.receiver.rowIds.count == 100 + Self.rounds * Self.samplesPerRound)
        #expect(god.fed.receiver.rowIds.count == 100 + Self.rounds * Self.samplesPerRound)
        #expect(ratio <= 1.2, "god p95 \(godP95) ns against small p95 \(smallP95) ns")
        small.fed.host.pageGone()
        god.fed.host.pageGone()
    }
}

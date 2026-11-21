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

    private typealias RoundSamples = (small: [UInt64], god: [UInt64])

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

    /// The bound is the median of each counted round's god p95 / small p95 ratio.
    private static func medianRoundRatio(_ rounds: [RoundSamples]) -> Double {
        #expect(!rounds.isEmpty, "at least one counted round is required")
        let ratios = rounds.map { round -> Double in
            #expect(!round.small.isEmpty, "a counted round has no small samples")
            #expect(!round.god.isEmpty, "a counted round has no god samples")
            return Double(p95(round.god)) / Double(max(p95(round.small), 1))
        }.sorted()
        guard !ratios.isEmpty else { return 0 }
        let middle = ratios.count / 2
        if ratios.count.isMultiple(of: 2) {
            return (ratios[middle - 1] + ratios[middle]) / 2
        }
        return ratios[middle]
    }

    @Test("v2.pr06.host_chat_change: one settled row, a chat of 100,000 rows within 1.2x of one of 100")
    func hostChatChange() async throws {
        var small = try await side(rows: 100)
        var god = try await side(rows: 100_000)
        var smallSamples: [UInt64] = []
        var godSamples: [UInt64] = []
        var countedRounds: [RoundSamples] = []
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
            countedRounds.append((small: s, god: g))
            smallSamples += s
            godSamples += g
        }
        let smallP95 = Self.p95(smallSamples)
        let godP95 = Self.p95(godSamples)
        let pooledRatio = Double(godP95) / Double(max(smallP95, 1))
        let roundRatios = countedRounds.map { round in
            Double(Self.p95(round.god)) / Double(max(Self.p95(round.small), 1))
        }
        let ratio = Self.medianRoundRatio(countedRounds)
        let largestRoundRatio = roundRatios.max() ?? 0
        for line in roundLines { print("v2.pr06.host_chat_change \(line)") }
        let roundsJSON = roundRatios.map { String(format: "%.3f", $0) }.joined(separator: ",")
        print("{\"name\":\"v2.pr06.host_chat_change\",\"small_p95\":\(smallP95),\"god_p95\":\(godP95),\"unit\":\"ns\",\"samples\":\(smallSamples.count),\"ratio\":\(String(format: "%.3f", ratio)),\"pooled_ratio\":\(String(format: "%.3f", pooledRatio)),\"round_ratios\":[\(roundsJSON)]}")
        #expect(smallSamples.count == godSamples.count)
        #expect(small.fed.receiver.rowIds.count == 100 + Self.rounds * Self.samplesPerRound)
        #expect(god.fed.receiver.rowIds.count == 100 + Self.rounds * Self.samplesPerRound)
        #expect(ratio <= 1.2, "median round ratio \(String(format: "%.3f", ratio)); largest round \(String(format: "%.3f", largestRoundRatio))")
        small.fed.host.pageGone()
        god.fed.host.pageGone()
    }

    @Test("per-round ratio is not the pooled ratio")
    func medianRoundRatioUsesCountedRounds() {
        func samples(_ p95: UInt64) -> [UInt64] { Array(repeating: p95, count: 100) }
        let logged: [(UInt64, UInt64)] = [
            (249_208, 264_500),
            (201_333, 241_792),
            (217_708, 253_417),
            (72_459, 81_834),
            (78_041, 81_917),
            (62_750, 62_958),
            (62_083, 73_333),
            (75_000, 69_833),
            (69_625, 65_625),
            (76_375, 78_666),
        ]
        let rounds = logged.dropFirst().map { (small: samples($0.0), god: samples($0.1)) }
        let pooledSmall = Self.p95(rounds.flatMap(\.small))
        let pooledGod = Self.p95(rounds.flatMap(\.god))
        let pooledRatio = Double(pooledGod) / Double(max(pooledSmall, 1))
        #expect(pooledRatio > 1.2)
        #expect(abs(Self.medianRoundRatio(rounds) - 1.0033147410358565) < 0.000_000_001)
    }

    @Test("every counted round over the bound fails the bound")
    func medianRoundRatioDetectsEverySlowRound() {
        let rounds: [RoundSamples] = (0..<9).map { _ in
            (small: Array(repeating: 100, count: 100), god: Array(repeating: 130, count: 100))
        }
        let ratio = Self.medianRoundRatio(rounds)
        #expect(abs(ratio - 1.3) < 0.000_000_001)
        #expect(ratio > 1.2, "median round ratio exceeds the 1.2x bound")
    }
}

@testable import CmuxLinkBench
import Testing

/// The harness itself, on A3's in-process loopback carrier: every workload
/// produces numbers, recovery sees the reconnect, nothing errors.
@Suite("bench harness", .serialized)
struct BenchHarnessTests {
    @Test("percentiles use nearest rank")
    func distribution() {
        let distribution = Distribution(milliseconds: (1...100).map(Double.init))
        #expect(distribution.p50 == 50)
        #expect(distribution.p95 == 95)
        #expect(distribution.p99 == 99)
        #expect(distribution.max == 100)
        #expect(Distribution(milliseconds: []).count == 0)
    }

    @Test("every workload runs on the loopback reference")
    func loopback() async {
        let report = await BenchRunner(spec: BenchSpec(rig: .reference, quick: true)).run()
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.coldConnect?.firstByte.count == 3)
        #expect((report.rttIdle?.count ?? 0) >= 10)
        #expect((report.terminalFlood?.receivedBytes ?? 0) > 0)
        #expect((report.bulkFile?.receivedBytes ?? 0) > 0)
        #expect(report.reconnect?.failures == 0)
        #expect(report.reconnect?.sessionReconnected.allSatisfy { $0 } == true)
        #expect(report.roam?.pathAfter.allSatisfy { $0 == "turn" } == true)
    }
}

@testable import CmuxLinkBench
import CmuxLinkDirect
import Foundation
import Testing

/// The harness itself, on A3's in-process loopback carrier: every workload
/// produces numbers, recovery sees the reconnect, nothing errors.
@Suite("bench harness", .serialized)
struct BenchHarnessTests {
    @Test("time limits propagate cancellation to the caller")
    func timeLimitCancellation() async {
        let task = Task {
            do {
                _ = try await TimeLimit(.seconds(30)).run {
                    try await Task.sleep(for: .seconds(30))
                    return true
                }
                return "returned"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "error: \(error)"
            }
        }

        task.cancel()
        #expect(await task.value == "cancelled")
    }

    @Test("runner stops scheduling workloads after cancellation")
    func runnerCancellationStopsLaterWorkloads() async {
        let calls = CallCounter()
        let runner = BenchRunner(spec: BenchSpec(rig: .v3, quick: true)) {
            await calls.increment()
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }

        let task = Task { await runner.run() }
        while await calls.value == 0 {
            await Task.yield()
        }
        task.cancel()
        _ = await task.value

        #expect(await calls.value == 1)
    }

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

    @Test("split descriptor and manifest round trip")
    func splitMetadata() throws {
        let host = DirectIdentity()
        let descriptor = BenchServeDescriptor(
            hostID: "bench-host", address: "127.0.0.1", port: 4180,
            hostKey: host.publicKey
        )
        let decoded = try BenchServeDescriptor.decode(JSONEncoder().encode(descriptor))
        #expect(decoded == descriptor)
        #expect(decoded.peer.hints["direct.hostKey"] == host.publicKey.base64)

        let manifest = try BenchResultManifest(
            name: "split", sourceCommit: "abc123", recordedAt: "2026-10-08",
            description: "split metadata", results: [.init(path: "run.json", role: "split-session")]
        )
        let roundTrip = try BenchResultManifest.decode(manifest.encoded())
        #expect(roundTrip == manifest)
        #expect(throws: BenchSplitError.self) {
            try BenchResultManifest(
                name: "bad", sourceCommit: "abc", recordedAt: "now", description: "bad",
                results: [.init(path: "../outside.json")]
            )
        }
        let base = URL(fileURLWithPath: "/tmp/cmux-bench")
        #expect(throws: BenchSplitError.self) {
            try BenchResultManifest.singleResult(
                name: "collision", sourceCommit: "abc", recordedAt: "now", description: "collision",
                resultURL: base.appendingPathComponent("same.json"),
                manifestURL: base.appendingPathComponent("same.json")
            )
        }
    }

    @Test("split direct server serves the shared echo workload")
    func splitDirectEcho() async throws {
        let server = BenchSplitServer(configuration: .init(
            hostID: "split-test", advertisedAddress: "127.0.0.1", localAddress: "127.0.0.1",
            port: 0, allowAnyDevice: true
        ))
        let descriptor = try await server.start()
        defer { Task { await server.stop() } }
        let client = try BenchSplitClient(descriptor: descriptor, deviceIdentity: DirectIdentity())
        var spec = BenchSpec(rig: .v3, quick: true, workloads: [.coldConnect])
        spec.bulkRecordBytes = descriptor.bulkRecordBytes
        let report = try await client.run(spec: spec)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.coldConnect?.firstByte.count == spec.connectSamples)
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

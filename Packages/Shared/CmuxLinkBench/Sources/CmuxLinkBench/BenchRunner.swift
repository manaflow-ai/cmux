import CmuxLink
import CmuxLinkTesting
import CmuxLinkWG
import CmuxLinkWGTesting
import Foundation

/// Runs the workloads of a spec against fresh endpoints of its rig. Every
/// workload gets its own connected fixture, so a stalled transfer cannot
/// leak into the next measurement, and every step has a wall-clock limit.
public struct BenchRunner: Sendable {
    public let spec: BenchSpec
    let rig: any ConformanceHarness
    let clock = ContinuousClock()

    public init(spec: BenchSpec) {
        self.spec = spec
        rig = Self.makeRig(spec)
    }

    init(spec: BenchSpec, rig: any ConformanceHarness) {
        self.spec = spec
        self.rig = rig
    }

    static func makeRig(_ spec: BenchSpec) -> any ConformanceHarness {
        let oneWay = Duration.microseconds(Int64(spec.rttMilliseconds * 500))
        switch spec.rig {
        case .v1:
            return WebRTCBenchRig()
        case .v2WebRTC:
            return WireGuardConformanceHarness(name: "v2-wg-over-webrtc-loopback") { WebRTCUnderlayRig().endpoints() }
        case .v2Memory:
            return WireGuardConformanceHarness(
                name: "v2-wg-in-memory",
                conditions: UnderlayConditions(latency: oneWay, loss: spec.loss)
            )
        case .v3:
            return DirectBenchRig()
        case .reference:
            return LoopbackHarness(name: "ref-a3-loopback", conditions: NetworkConditions(latency: oneWay, loss: spec.loss))
        }
    }

    public func run(progress: @Sendable (String) -> Void = { _ in }) async -> BenchReport {
        let baseline = ProcessUsage()
        let started = clock.now
        var report = BenchReport(
            rig: rig.name,
            carrier: spec.rig.carrier,
            conditions: conditions,
            machine: MachineInfo.current(),
            startedAt: ISO8601DateFormatter().string(from: Date())
        )
        func attempt<T>(_ workload: BenchWorkload, _ body: () async throws -> T) async -> T? {
            guard spec.runs(workload) else { return nil }
            progress("\(rig.name): \(workload.rawValue)")
            do {
                return try await body()
            } catch {
                report.errors.append("\(workload.rawValue): \(error)")
                progress("  error: \(error)")
                return nil
            }
        }
        report.coldConnect = await attempt(.coldConnect) { try await coldConnect() }
        report.rttIdle = await attempt(.rttIdle) { try await rttIdle() }
        report.rttUnderBulk = await attempt(.rttUnderBulk) { try await rttUnderBulk() }
        if var underBulk = report.rttUnderBulk, let idle = report.rttIdle {
            underBulk.p50DeltaMilliseconds = underBulk.rtt.p50 - idle.p50
            underBulk.p99DeltaMilliseconds = underBulk.rtt.p99 - idle.p99
            report.rttUnderBulk = underBulk
        }
        report.terminalFlood = await attempt(.terminalFlood) {
            try await download(stream: "bench/flood", priority: .render, recordBytes: 4 * 1024)
        }
        report.bulkFile = await attempt(.bulkFile) {
            try await download(stream: "bench/bulk", priority: .bulk, recordBytes: spec.bulkRecordBytes)
        }
        report.rawTransport = await attempt(.rawTransport) { try await rawDownload(recordBytes: spec.bulkRecordBytes) }
        report.reconnect = await attempt(.reconnect) { try await recovery(.drop) }
        report.roam = await attempt(.roam) { try await recovery(.roam) }
        let final = ProcessUsage()
        report.memory = MemoryResult(
            baselineMaxResidentMiB: Double(baseline.maxResidentBytes) / 1_048_576,
            finalMaxResidentMiB: Double(final.maxResidentBytes) / 1_048_576,
            finalFootprintMiB: Double(final.footprintBytes) / 1_048_576
        )
        report.durationSeconds = (clock.now - started).milliseconds / 1_000
        return report
    }

    private var conditions: BenchConditions {
        if spec.rig.shapeable {
            return BenchConditions(
                shaped: true, rttMilliseconds: spec.rttMilliseconds, loss: spec.loss,
                note: spec.rig == .v2Memory
                    ? "in-memory underlay: fixed one-way delay, independent datagram loss, no rate limit, 1200 B datagrams"
                    : "A3 simulated carrier: loss on reliable lanes costs a retransmission delay"
            )
        }
        return BenchConditions(
            shaped: false, rttMilliseconds: 0, loss: 0,
            note: "real sockets on loopback; shape with the dnctl recipe in d2-bakeoff.md"
        )
    }

    /// Opens a fixture, runs `body`, always shuts it down.
    func withFixture<T: Sendable>(_ body: (BenchFixture) async throws -> T) async throws -> T {
        let fixture = try await BenchFixture.connect(rig)
        do {
            let value = try await body(fixture)
            await fixture.shutdown()
            return value
        } catch {
            await fixture.shutdown()
            throw error
        }
    }
}

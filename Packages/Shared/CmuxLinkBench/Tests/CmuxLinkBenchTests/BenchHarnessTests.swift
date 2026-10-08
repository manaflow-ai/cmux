@testable import CmuxLinkBench
import CmuxLink
import CmuxLinkDirect
import CmuxLinkSignaling
import CmuxLinkTesting
import CmuxLinkWebRTC
import CmuxLinkWG
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

    @Test("fixture setup cancellation tears down the rig")
    func fixtureSetupCancellationCleansUp() async {
        let harness = CancellationHarness()
        let task = Task {
            do {
                _ = try await BenchFixture.connect(harness, limit: .seconds(30))
                return "returned"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "error: \(error)"
            }
        }
        await harness.tracker.waitForMake()
        task.cancel()

        #expect(await task.value == "cancelled")
        #expect(await harness.tracker.teardownCount == 1)
    }

    @Test("raw benchmark cancellation tears down the rig")
    func rawBenchmarkCancellationCleansUp() async {
        let harness = CancellationHarness()
        let runner = BenchRunner(spec: BenchSpec(rig: .v3, quick: true), rig: harness)
        let task = Task {
            do {
                _ = try await runner.rawDownload(recordBytes: 1_024)
                return "returned"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "error: \(error)"
            }
        }
        await harness.tracker.waitForMake()
        task.cancel()

        #expect(await task.value == "cancelled")
        #expect(await harness.tracker.teardownCount == 1)
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
        let provenance = BenchReportProvenance(
            sourceGitSHA: "0123456789abcdef", devTag: "nxd3", buildNumber: "42", runID: "run-1"
        )
        let provenanceRoundTrip = try JSONDecoder().decode(
            BenchReportProvenance.self, from: JSONEncoder().encode(provenance)
        )
        #expect(provenanceRoundTrip == provenance)
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

    @Test("split signaling adapters pin V1 and V2 keys")
    func splitSignalingAdapters() throws {
        let directHost = DirectIdentity()
        let webrtcHost = SoftwareWebRTCIdentity()
        let wireGuardHost = WireGuardPrivateKey()
        let descriptor = BenchServeDescriptor(
            hostID: "signal-host", address: "", port: 0, hostKey: directHost.publicKey,
            webrtcHostKey: webrtcHost.publicKey.base64,
            wireGuardHostKey: wireGuardHost.publicKey.base64,
            signalTarget: "inst_signal-host",
            carriers: [.webrtc, .webrtcWireGuard]
        )
        try descriptor.validate()
        #expect(descriptor.peer.hints[WebRTCHintsResolver.hostKeyHint] == webrtcHost.publicKey.base64)
        #expect(descriptor.peer.hints[WireGuardHintsResolver.hostKeyHint] == wireGuardHost.publicKey.base64)
        #expect(descriptor.peer.hints[WebRTCHintsResolver.signalTargetHint] == "inst_signal-host")

        let hub = InMemorySignalingHub()
        let adapters = try BenchSignalingAdapters(
            channel: hub.endpoint(id: "in_bench"),
            iceServers: StaticICEServerProvider(),
            webrtcIdentity: SoftwareWebRTCIdentity(),
            wireGuardIdentity: WireGuardPrivateKey(),
            wireGuardInstallID: "in_bench"
        )
        let v1 = try adapters.carriers(for: descriptor, selecting: .v1)
        let v2 = try adapters.carriers(for: descriptor, selecting: .v2WebRTC)
        #expect(v1.map(\.kind) == [.webrtc])
        #expect(v2.map(\.kind) == [.webrtcWireGuard])
    }

    @Test("accepting host constructs and owns V1 and V2 listeners")
    func acceptingHostWiring() async throws {
        let hub = InMemorySignalingHub()
        let deviceWebRTC = SoftwareWebRTCIdentity()
        let deviceWireGuard = WireGuardPrivateKey()
        let host = try BenchAcceptingHost(
            hostID: "accept-host",
            router: SignalRouter(channel: hub.endpoint(id: "accept-host")),
            iceServers: StaticICEServerProvider(.hostOnly),
            webrtcIdentity: SoftwareWebRTCIdentity(),
            wireGuardIdentity: WireGuardPrivateKey(),
            allowedWebRTCDevices: [deviceWebRTC.publicKey],
            allowedWireGuardDevices: [deviceWireGuard.publicKey],
            webrtcConfiguration: .init(network: .loopbackOnly)
        )
        #expect(!host.webrtcHostKey.isEmpty)
        #expect(!host.wireGuardHostKey.isEmpty)

        let v1 = try host.makeAcceptor(for: .v1)
        await v1.start()
        await v1.stop()
        let v2 = try host.makeAcceptor(for: .v2WebRTC)
        await v2.start()
        await v2.stop()
    }

    @Test("accepting host refuses unpaired devices and unsupported rigs")
    func acceptingHostRequiresTrustAndRig() throws {
        let hub = InMemorySignalingHub()
        #expect(throws: BenchSplitError.self) {
            try BenchAcceptingHost(
                hostID: "accept-host",
                router: SignalRouter(channel: hub.endpoint(id: "accept-host")),
                iceServers: StaticICEServerProvider(),
                webrtcIdentity: SoftwareWebRTCIdentity(),
                wireGuardIdentity: WireGuardPrivateKey(),
                allowedWebRTCDevices: [],
                allowedWireGuardDevices: []
            )
        }
        let host = try BenchAcceptingHost(
            hostID: "accept-host",
            router: SignalRouter(channel: hub.endpoint(id: "accept-host-2")),
            iceServers: StaticICEServerProvider(),
            webrtcIdentity: SoftwareWebRTCIdentity(),
            wireGuardIdentity: WireGuardPrivateKey(),
            allowedWebRTCDevices: [SoftwareWebRTCIdentity().publicKey],
            allowedWireGuardDevices: []
        )
        #expect(throws: BenchSplitError.self) { try host.makeAcceptor(for: .v3) }
    }

    @Test("signaling descriptor rejects a missing selected host key")
    func signalingDescriptorRequiresPinnedKey() throws {
        let descriptor = BenchServeDescriptor(
            hostID: "signal-host", address: "", port: 0, hostKey: DirectIdentity().publicKey,
            carriers: [.webrtc]
        )
        #expect(throws: BenchSplitError.self) { try descriptor.validate() }
    }

    @Test("split entry points resolve one carrier and reject ambiguous descriptors")
    func splitEntryPointSelection() throws {
        let direct = BenchServeDescriptor(
            hostID: "direct-host", address: "127.0.0.1", port: 4180,
            hostKey: DirectIdentity().publicKey
        )
        #expect(try BenchSplitClient.resolveRig(nil, descriptor: direct) == .v3)
        #expect(try BenchSplitClient.resolveRig(.v3, descriptor: direct) == .v3)
        #expect(throws: BenchSplitError.self) {
            try BenchSplitClient.resolveRig(.v1, descriptor: direct)
        }

        let signaling = BenchServeDescriptor(
            hostID: "signal-host", address: "", port: 0,
            hostKey: DirectIdentity().publicKey,
            webrtcHostKey: SoftwareWebRTCIdentity().publicKey.base64,
            carriers: [.webrtc]
        )
        #expect(try BenchSplitClient.resolveRig(nil, descriptor: signaling) == .v1)

        let wireGuard = BenchServeDescriptor(
            hostID: "wg-host", address: "", port: 0,
            hostKey: DirectIdentity().publicKey,
            wireGuardHostKey: WireGuardPrivateKey().publicKey.base64,
            carriers: [.webrtcWireGuard]
        )
        #expect(try BenchSplitClient.resolveRig(nil, descriptor: wireGuard) == .v2WebRTC)

        let mixed = BenchServeDescriptor(
            hostID: "mixed-host", address: "127.0.0.1", port: 4180,
            hostKey: DirectIdentity().publicKey,
            webrtcHostKey: SoftwareWebRTCIdentity().publicKey.base64,
            carriers: [.direct, .webrtc]
        )
        #expect(throws: BenchSplitError.self) {
            try BenchSplitClient.resolveRig(nil, descriptor: mixed)
        }
        #expect(try BenchSplitClient.resolveRig(.v1, descriptor: mixed) == .v1)
        #expect(throws: BenchSplitError.self) {
            try BenchSplitClient.resolveRig(.v2Memory, descriptor: direct)
        }
    }

    @Test("split server rejects an unavailable signaling rig before listening")
    func splitServerRejectsUnavailableRig() async throws {
        for rig in [BenchRigKind.v1, .v2WebRTC] {
            let server = BenchSplitServer(configuration: .init(allowAnyDevice: true))
            await #expect(throws: BenchSplitError.self) {
                try await server.start(rig: rig)
            }
            let descriptor = try await server.start(rig: .v3)
            #expect(descriptor.carriers == [CarrierKind.direct.rawValue])
            await server.stop()
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

private actor CleanupTracker {
    private var made = false
    private(set) var teardownCount = 0

    func markMade() {
        made = true
    }

    func waitForMake() async {
        while !made {
            await Task.yield()
        }
    }

    func recordTeardown() {
        teardownCount += 1
    }
}

private final class BlockingCarrier: LinkCarrier, @unchecked Sendable {
    let kind: CarrierKind = .direct
    let candidatePaths: [PathKind] = [.direct]

    func connect(to _: LinkPeer) async throws -> any LinkTransport {
        try await Task.sleep(for: .seconds(3_600))
        throw CancellationError()
    }
}

private final class BlockingAcceptor: LinkAcceptor, @unchecked Sendable {
    let incoming: AsyncStream<any LinkTransport>
    private let continuation: AsyncStream<any LinkTransport>.Continuation

    init() {
        (incoming, continuation) = AsyncStream.makeStream(of: (any LinkTransport).self)
    }

    deinit {
        continuation.finish()
    }
}

private final class CancellationHarness: ConformanceHarness, @unchecked Sendable {
    let name = "cancellation"
    let tracker = CleanupTracker()
    private let carrier = BlockingCarrier()
    private let acceptor = BlockingAcceptor()

    func makeEndpoints() async throws -> ConformanceEndpoints {
        await tracker.markMade()
        return ConformanceEndpoints(carriers: [carrier], acceptor: acceptor)
    }

    func tearDown() async {
        await tracker.recordTeardown()
    }
}

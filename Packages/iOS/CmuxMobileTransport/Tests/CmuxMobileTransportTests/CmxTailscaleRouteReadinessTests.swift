import CMUXMobileCore
import Foundation
import Network
import Testing
@testable import CmuxMobileTransport

private let tailscaleIdentity = CmxNetworkInterfaceIdentity(name: "utun4", index: 22)
private let wifiIdentity = CmxNetworkInterfaceIdentity(name: "en0", index: 15)

/// Behavior coverage for the QR-scan-during-Tailscale-bring-up race: route
/// preparation must park on real path observations, succeed the moment the
/// tunnel becomes provable, fail with the readiness error (not a hang) when
/// it never does, and unblock immediately on cancellation.
@Suite struct CmxTailscaleRouteReadinessTests {
    @Test func firstScanWaitsThroughTunnelBringUpThenSucceeds() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )
        let request = try tailscaleRequest()

        let prepared = Task { try await readiness.prepare(request: request) }
        // The scan happened before NWPathMonitor delivered anything: prepare
        // must park rather than judge the monitor's startup snapshot.
        try await waitForParkedWaiter(readiness)

        // First real observation: Wi-Fi only, tunnel not up yet. Prepare must
        // keep waiting instead of failing the pairing attempt.
        await readiness.ingest(wifiOnlyObservation(sequence: 1))
        try await waitForParkedWaiter(readiness)

        // Tunnel appears: the parked preparation completes with a proof bound
        // to the tunnel observation and its platform interface token.
        await readiness.ingest(tailscaleObservation(sequence: 2))
        let route = try await prepared.value
        #expect(route.proof.interface == tailscaleIdentity)
        #expect(route.interface == "token-utun4")
        #expect(route.proof.generation == 2)

        try await readiness.validate(
            proof: route.proof,
            connectionPath: connectionPath()
        )
    }

    @Test func deadlineExpiryThrowsReadinessErrorWithLastFailure() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )
        await readiness.ingest(wifiOnlyObservation(sequence: 1))

        let prepared = Task { try await readiness.prepare(request: try tailscaleRequest()) }
        try await waitForParkedWaiter(readiness)
        try await waitForSleeper(clock)

        clock.advance(by: .seconds(10))
        await #expect(throws: CmxTailscaleReadinessError.deadlineExpired(
            lastFailure: .tailscaleInterfaceUnavailable
        )) {
            try await prepared.value
        }
    }

    @Test func deadlineExpiryWithoutAnyObservationReportsNoPath() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )

        let prepared = Task { try await readiness.prepare(request: try tailscaleRequest()) }
        try await waitForParkedWaiter(readiness)
        try await waitForSleeper(clock)

        clock.advance(by: .seconds(10))
        await #expect(throws: CmxTailscaleReadinessError.deadlineExpired(
            lastFailure: nil
        )) {
            try await prepared.value
        }
    }

    @Test func cancellationUnblocksParkedPreparation() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )

        let prepared = Task { try await readiness.prepare(request: try tailscaleRequest()) }
        try await waitForParkedWaiter(readiness)

        prepared.cancel()
        await #expect(throws: CancellationError.self) {
            try await prepared.value
        }
    }

    @Test func nonTransientProofFailureFailsImmediately() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )
        await readiness.ingest(tailscaleObservation(sequence: 1))

        let mismatchedEvidence = try CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "mac-2",
            host: "100.71.210.41",
            port: 58_465
        )
        let request = try tailscaleRequest(
            authorizationMode: .legacyTailscaleBearer(mismatchedEvidence)
        )

        await #expect(throws: CmxTailscaleRouteProofError.authorizationEvidenceMismatch) {
            try await readiness.prepare(request: request)
        }
    }

    @Test func staleObservationCannotRegressReadyState() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )
        // Capture order is authoritative: the tunnel observation was captured
        // after the Wi-Fi-only one, so the late-arriving stale capture must
        // not knock readiness back down.
        await readiness.ingest(tailscaleObservation(sequence: 2))
        await readiness.ingest(wifiOnlyObservation(sequence: 1))

        let route = try await readiness.prepare(request: tailscaleRequest())
        #expect(route.proof.interface == tailscaleIdentity)
        try await readiness.validate(
            proof: route.proof,
            connectionPath: connectionPath()
        )
    }

    @Test func duplicateObservationKeepsProofGenerationValid() async throws {
        let clock = ManualClock()
        let readiness = CmxTailscaleRouteReadiness<String>(
            clock: clock,
            readinessDeadline: .seconds(10)
        )
        await readiness.ingest(tailscaleObservation(sequence: 1))
        let route = try await readiness.prepare(request: tailscaleRequest())

        // NWPathMonitor delivers duplicate callbacks; identical content must
        // not invalidate an already-proven route.
        await readiness.ingest(tailscaleObservation(sequence: 2))
        try await readiness.validate(
            proof: route.proof,
            connectionPath: connectionPath()
        )

        // A real content change must invalidate it.
        var interfaces = [tailscaleIdentity: "token-utun4", wifiIdentity: "token-en0"]
        let second = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)
        interfaces[second] = "token-utun5"
        await readiness.ingest(CmxTailscalePathObservation(
            sequence: 3,
            pathSatisfied: true,
            interfaces: interfaces,
            systemInterfaces: [
                interfaceSnapshot(
                    identity: tailscaleIdentity,
                    addresses: ["100.70.231.80"]
                ),
                interfaceSnapshot(identity: second, addresses: ["100.68.1.2"]),
            ]
        ))
        await #expect(throws: CmxTailscaleRouteProofError.routeGenerationChanged) {
            try await readiness.validate(
                proof: route.proof,
                connectionPath: connectionPath()
            )
        }
    }

    @Test func closingPreparingTransportCancelsParkedPreparation() async throws {
        let authority = ParkedTailscaleAuthority()
        let transport = CmxPreparingTailscaleByteTransport(
            request: try tailscaleRequest(),
            tailscaleRouteAuthority: authority,
            maximumReceiveLength: 64 * 1024,
            connectTimeoutNanoseconds: 1_000_000_000
        )

        let connect = Task { try await transport.connect() }
        // Deterministic ordering: close only after preparation actually parked.
        try await waitUntil { await authority.parkedCount == 1 }

        await transport.close()
        await #expect(throws: CancellationError.self) {
            try await connect.value
        }
    }
}

/// Parks `prepare` forever (cancellation-aware) so tests can prove that
/// closing the transport unblocks a suspended preparation.
private actor ParkedTailscaleAuthority: CmxTailscaleRouteAuthorizing {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var parkedCount = 0

    func prepare(request _: CmxByteTransportRequest) async throws -> CmxPreparedTailscaleRoute {
        let id = UUID()
        parkedCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                continuations[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        throw CancellationError()
    }

    func validate(
        proof _: CmxTailscaleRouteProof,
        connectionPath _: NWPath,
        phase _: CmxTailscaleRouteValidationPhase
    ) throws {
        throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
    }

    private func cancel(id: UUID) {
        continuations.removeValue(forKey: id)?
            .resume(throwing: CancellationError())
    }
}

private func waitForParkedWaiter(
    _ readiness: CmxTailscaleRouteReadiness<String>,
    count: Int = 1
) async throws {
    try await waitUntil { await readiness.pendingWaiterCount == count }
}

private func waitForSleeper(_ clock: ManualClock) async throws {
    try await waitUntil { clock.sleeperCount == 1 }
}

private func waitUntil(
    _ condition: () async -> Bool
) async throws {
    for _ in 0 ..< 4000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition never became true")
}

private func tailscaleRequest(
    authorizationMode: CmxTransportAuthorizationMode? = nil
) throws -> CmxByteTransportRequest {
    let host = "100.71.210.41"
    let port = 58_465
    let mode = try authorizationMode ?? .legacyTailscaleBearer(
        CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "mac-1",
            host: host,
            port: port
        )
    )
    return CmxByteTransportRequest(
        route: try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        ),
        expectedPeerDeviceID: "mac-1",
        authorizationMode: mode
    )
}

private func wifiOnlyObservation(sequence: UInt64) -> CmxTailscalePathObservation<String> {
    CmxTailscalePathObservation(
        sequence: sequence,
        pathSatisfied: true,
        interfaces: [wifiIdentity: "token-en0"],
        systemInterfaces: [
            interfaceSnapshot(identity: wifiIdentity, addresses: ["192.168.1.10"])
        ]
    )
}

private func tailscaleObservation(sequence: UInt64) -> CmxTailscalePathObservation<String> {
    CmxTailscalePathObservation(
        sequence: sequence,
        pathSatisfied: true,
        interfaces: [
            wifiIdentity: "token-en0",
            tailscaleIdentity: "token-utun4",
        ],
        systemInterfaces: [
            interfaceSnapshot(identity: wifiIdentity, addresses: ["192.168.1.10"]),
            interfaceSnapshot(
                identity: tailscaleIdentity,
                addresses: ["100.70.231.80", "fd7a:115c:a1e0::6c36:e750"]
            ),
        ]
    )
}

private func interfaceSnapshot(
    identity: CmxNetworkInterfaceIdentity,
    addresses: [String]
) -> CmxTailscaleInterfaceSnapshot {
    CmxTailscaleInterfaceSnapshot(
        identity: identity,
        isUp: true,
        isRunning: true,
        addresses: Set(addresses.compactMap(CmxTailscaleIPAddress.init))
    )
}

private func connectionPath(
    remoteAddress: String = "100.71.210.41",
    remotePort: Int = 58_465
) -> CmxTailscaleConnectionPathSnapshot {
    CmxTailscaleConnectionPathSnapshot(
        isSatisfied: true,
        availableInterfaces: [tailscaleIdentity],
        localAddress: CmxTailscaleIPAddress("100.70.231.80"),
        remoteAddress: CmxTailscaleIPAddress(remoteAddress),
        remotePort: remotePort
    )
}

import CMUXMobileCore
import Testing
@testable import CmuxMobileTransport

private let tailscaleInterface = CmxNetworkInterfaceIdentity(name: "utun4", index: 22)

@Suite struct CmxTailscaleRouteProofTests {
    @Test func rejectsGenericBearerAndMismatchedLegacyEvidence() throws {
        let genericBearer = try tailscaleRequest(
            host: "100.71.210.41",
            authorizationMode: .stackBearer
        )
        let mismatchedEvidence = try CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "mac-2",
            host: "100.71.210.41",
            port: 58_465
        )
        let mismatch = try tailscaleRequest(
            host: "100.71.210.41",
            authorizationMode: .legacyTailscaleBearer(mismatchedEvidence)
        )
        let snapshot = authoritySnapshot(generation: 1)

        #expect(throws: CmxTailscaleRouteProofError.unsupportedAuthorizationMode) {
            _ = try CmxTailscaleRouteProofValidator().prepare(
                request: genericBearer,
                snapshot: snapshot
            )
        }
        #expect(throws: CmxTailscaleRouteProofError.authorizationEvidenceMismatch) {
            _ = try CmxTailscaleRouteProofValidator().prepare(
                request: mismatch,
                snapshot: snapshot
            )
        }
    }

    @Test func rejectsWhenNoUnambiguousLiveTailscaleInterfaceExists() throws {
        let request = try tailscaleRequest(host: "100.71.210.41")
        let noTailscale = CmxTailscaleAuthoritySnapshot(
            generation: 1,
            pathSatisfied: true,
            availableInterfaces: [CmxNetworkInterfaceIdentity(name: "en0", index: 15)],
            systemInterfaces: [
                interface(name: "en0", index: 15, addresses: ["192.168.1.10"])
            ]
        )
        let second = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)
        let ambiguous = CmxTailscaleAuthoritySnapshot(
            generation: 1,
            pathSatisfied: true,
            availableInterfaces: [tailscaleInterface, second],
            systemInterfaces: [
                interface(name: "utun4", index: 22, addresses: ["100.70.231.80"]),
                interface(name: "utun5", index: 23, addresses: ["100.68.1.2"]),
            ]
        )

        #expect(throws: CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable) {
            _ = try CmxTailscaleRouteProofValidator().prepare(
                request: request,
                snapshot: noTailscale
            )
        }
        #expect(throws: CmxTailscaleRouteProofError.ambiguousTailscaleInterfaces) {
            _ = try CmxTailscaleRouteProofValidator().prepare(
                request: request,
                snapshot: ambiguous
            )
        }
    }

    @Test func validatesExactInterfaceBoundIPv4AndIPv6Peers() throws {
        let snapshot = authoritySnapshot(generation: 41)
        let ipv4 = try tailscaleRequest(host: "100.71.210.41")
        let ipv4Proof = try CmxTailscaleRouteProofValidator().prepare(
            request: ipv4,
            snapshot: snapshot
        )
        try CmxTailscaleRouteProofValidator().validate(
            proof: ipv4Proof,
            authoritySnapshot: snapshot,
            connectionPath: connectionPath()
        )

        let ipv6 = try tailscaleRequest(host: "fd7a:115c:a1e0::1234")
        let ipv6Proof = try CmxTailscaleRouteProofValidator().prepare(
            request: ipv6,
            snapshot: snapshot
        )
        try CmxTailscaleRouteProofValidator().validate(
            proof: ipv6Proof,
            authoritySnapshot: snapshot,
            connectionPath: connectionPath(remoteAddress: "fd7a:115c:a1e0::1234")
        )

        #expect(ipv4Proof.interface == tailscaleInterface)
        #expect(ipv4Proof.request.expectedPeerDeviceID == "mac-1")
    }

    @Test func rejectsGenerationInterfaceAndEffectiveEndpointSubstitution() throws {
        let request = try tailscaleRequest(host: "100.71.210.41")
        let snapshot = authoritySnapshot(generation: 41)
        let proof = try CmxTailscaleRouteProofValidator().prepare(
            request: request,
            snapshot: snapshot
        )
        let replacement = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)

        #expect(throws: CmxTailscaleRouteProofError.routeGenerationChanged) {
            try CmxTailscaleRouteProofValidator().validate(
                proof: proof,
                authoritySnapshot: authoritySnapshot(generation: 42),
                connectionPath: connectionPath()
            )
        }
        #expect(throws: CmxTailscaleRouteProofError.connectionPathUnavailable) {
            try CmxTailscaleRouteProofValidator().validate(
                proof: proof,
                authoritySnapshot: snapshot,
                connectionPath: CmxTailscaleConnectionPathSnapshot(
                    isSatisfied: true,
                    availableInterfaces: [replacement],
                    localAddress: CmxTailscaleIPAddress("100.70.231.80"),
                    remoteAddress: CmxTailscaleIPAddress("100.71.210.41"),
                    remotePort: 58_465
                )
            )
        }
        #expect(throws: CmxTailscaleRouteProofError.remoteEndpointMismatch) {
            try CmxTailscaleRouteProofValidator().validate(
                proof: proof,
                authoritySnapshot: snapshot,
                connectionPath: connectionPath(remoteAddress: "100.71.210.42")
            )
        }
        #expect(throws: CmxTailscaleRouteProofError.remotePortMismatch) {
            try CmxTailscaleRouteProofValidator().validate(
                proof: proof,
                authoritySnapshot: snapshot,
                connectionPath: connectionPath(remotePort: 58_466)
            )
        }
    }

    @Test func authorizationFailureCannotReachSendBoundary() async throws {
        let transport = try CmxNetworkByteTransport(host: "127.0.0.1", port: 58_465)
        var didBeginWrite = false

        await #expect(throws: CmxTailscaleRouteProofError.routeGenerationChanged) {
            try await transport.performAuthorizedWrite(
                authorization: {
                    throw CmxTailscaleRouteProofError.routeGenerationChanged
                },
                beginWrite: {
                    didBeginWrite = true
                }
            )
        }
        #expect(!didBeginWrite)
    }
}

private func tailscaleRequest(
    host: String,
    authorizationMode: CmxTransportAuthorizationMode? = nil
) throws -> CmxByteTransportRequest {
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

private func authoritySnapshot(generation: UInt64) -> CmxTailscaleAuthoritySnapshot {
    CmxTailscaleAuthoritySnapshot(
        generation: generation,
        pathSatisfied: true,
        availableInterfaces: [tailscaleInterface],
        systemInterfaces: [
            interface(
                name: tailscaleInterface.name,
                index: tailscaleInterface.index,
                addresses: ["100.70.231.80", "fd7a:115c:a1e0::6c36:e750"]
            )
        ]
    )
}

private func interface(
    name: String,
    index: Int,
    addresses: [String]
) -> CmxTailscaleInterfaceSnapshot {
    CmxTailscaleInterfaceSnapshot(
        identity: CmxNetworkInterfaceIdentity(name: name, index: index),
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
        availableInterfaces: [tailscaleInterface],
        localAddress: CmxTailscaleIPAddress("100.70.231.80"),
        remoteAddress: CmxTailscaleIPAddress(remoteAddress),
        remotePort: remotePort
    )
}

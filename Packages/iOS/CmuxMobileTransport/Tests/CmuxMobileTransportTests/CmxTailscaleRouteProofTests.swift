import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

private let tailscaleInterface = CmxNetworkInterfaceIdentity(name: "utun4", index: 22)

@Test func rejectsWhenTailscaleVPNIsOff() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let snapshot = CmxTailscaleAuthoritySnapshot(
        generation: 1,
        pathSatisfied: true,
        availableInterfaces: [CmxNetworkInterfaceIdentity(name: "en0", index: 15)],
        systemInterfaces: [
            interface(name: "en0", index: 15, addresses: ["192.168.1.10"])
        ]
    )

    #expect(throws: CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: request,
            snapshot: snapshot
        )
    }
}

@Test func rejectsCGNATAddressOnANonTailscaleInterface() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let en0 = CmxNetworkInterfaceIdentity(name: "en0", index: 15)
    let snapshot = CmxTailscaleAuthoritySnapshot(
        generation: 1,
        pathSatisfied: true,
        availableInterfaces: [en0],
        systemInterfaces: [
            interface(name: "en0", index: 15, addresses: ["100.70.231.80"])
        ]
    )

    #expect(throws: CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: request,
            snapshot: snapshot
        )
    }
}

@Test func rejectsCGNATPeerWhenOnlyAnotherVPNInterfaceIsActive() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let otherVPN = CmxNetworkInterfaceIdentity(name: "utun8", index: 26)
    let snapshot = CmxTailscaleAuthoritySnapshot(
        generation: 1,
        pathSatisfied: true,
        availableInterfaces: [otherVPN],
        systemInterfaces: [
            interface(name: "utun8", index: 26, addresses: ["10.8.0.2"])
        ]
    )

    #expect(throws: CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: request,
            snapshot: snapshot
        )
    }
}

@Test func documentsTailscaleInterfaceHeuristicBoundary() throws {
    // Apple exposes packet tunnels as anonymous utun interfaces. The
    // strongest entitlement-free identity is therefore: up + running utun,
    // visible to NWPath, with a Tailscale-range self address. A different
    // VPN deliberately configured with that same range is indistinguishable,
    // which is why exact requiredInterface and effective endpoints are also
    // rechecked at every write.
    let request = try tailscaleRequest(host: "100.71.210.41")
    let candidate = CmxNetworkInterfaceIdentity(name: "utun8", index: 26)
    let snapshot = CmxTailscaleAuthoritySnapshot(
        generation: 1,
        pathSatisfied: true,
        availableInterfaces: [candidate],
        systemInterfaces: [
            interface(name: "utun8", index: 26, addresses: ["100.70.231.80"])
        ]
    )

    let proof = try CmxTailscaleRouteProofValidator().prepare(
        request: request,
        snapshot: snapshot
    )

    #expect(proof.interface == candidate)
}

@Test func rejectsInterfaceGenerationChangeAtWriteBoundary() async throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let preparedSnapshot = authoritySnapshot(generation: 41)
    let proof = try CmxTailscaleRouteProofValidator().prepare(
        request: request,
        snapshot: preparedSnapshot
    )
    let replacement = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)
    let changedSnapshot = CmxTailscaleAuthoritySnapshot(
        generation: 42,
        pathSatisfied: true,
        availableInterfaces: [replacement],
        systemInterfaces: [
            interface(name: "utun5", index: 23, addresses: ["100.70.231.80"])
        ]
    )
    let transport = try CmxNetworkByteTransport(
        host: "127.0.0.1",
        port: 58465
    )

    await #expect(throws: CmxTailscaleRouteProofError.routeGenerationChanged) {
        try await transport.performAuthorizedWrite(
            authorization: {
                try CmxTailscaleRouteProofValidator().validate(
                    proof: proof,
                    authoritySnapshot: changedSnapshot,
                    connectionPath: connectionPath()
                )
            },
            beginWrite: {
                Issue.record("generation race must not reach the bearer write")
            }
        )
    }
}

@Test func rejectsSameGenerationInterfaceSubstitution() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let proof = try CmxTailscaleRouteProofValidator().prepare(
        request: request,
        snapshot: authoritySnapshot(generation: 41)
    )
    let replacement = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)
    let changedSnapshot = CmxTailscaleAuthoritySnapshot(
        generation: 41,
        pathSatisfied: true,
        availableInterfaces: [replacement],
        systemInterfaces: [
            interface(name: "utun5", index: 23, addresses: ["100.70.231.80"])
        ]
    )

    #expect(throws: CmxTailscaleRouteProofError.interfaceChanged) {
        try CmxTailscaleRouteProofValidator().validate(
            proof: proof,
            authoritySnapshot: changedSnapshot,
            connectionPath: connectionPath()
        )
    }
}

@Test func rejectsMagicDNSAndSubstitutedDNSResults() throws {
    let magicDNS = try tailscaleRequest(host: "work-mac.tailnet.ts.net")
    let substitutedPublicAddress = try tailscaleRequest(host: "203.0.113.10")
    let genericPrivateNetwork = try tailscaleRequest(host: "192.168.1.20")
    let snapshot = authoritySnapshot(generation: 1)

    #expect(throws: CmxTailscaleRouteProofError.nonNumericPeer) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: magicDNS,
            snapshot: snapshot
        )
    }
    #expect(throws: CmxTailscaleRouteProofError.peerOutsideTailscaleRange) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: substitutedPublicAddress,
            snapshot: snapshot
        )
    }
    #expect(throws: CmxTailscaleRouteProofError.peerOutsideTailscaleRange) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: genericPrivateNetwork,
            snapshot: snapshot
        )
    }
}

@Test func rejectsRouteKindAndAuthorizationModeSubstitution() throws {
    let loopbackRoute = try CmxAttachRoute(
        id: "substituted",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "100.71.210.41", port: 58465)
    )
    let routeSubstitution = CmxByteTransportRequest(
        route: loopbackRoute,
        expectedPeerDeviceID: "mac-1",
        authorizationMode: .stackBearer
    )
    let authorizationSubstitution = try tailscaleRequest(
        host: "100.71.210.41",
        authorizationMode: .transportAdmission
    )
    let snapshot = authoritySnapshot(generation: 1)

    #expect(throws: CmxTailscaleRouteProofError.unsupportedRouteKind) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: routeSubstitution,
            snapshot: snapshot
        )
    }
    #expect(throws: CmxTailscaleRouteProofError.unsupportedAuthorizationMode) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: authorizationSubstitution,
            snapshot: snapshot
        )
    }
}

@Test func validatesSuccessfulInterfaceBoundTailscaleIPv4Write() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let snapshot = authoritySnapshot(generation: 41)
    let proof = try CmxTailscaleRouteProofValidator().prepare(
        request: request,
        snapshot: snapshot
    )

    try CmxTailscaleRouteProofValidator().validate(
        proof: proof,
        authoritySnapshot: snapshot,
        connectionPath: connectionPath()
    )
    #expect(proof.request.expectedPeerDeviceID == "mac-1")
    #expect(proof.interface == tailscaleInterface)
}

@Test func validatesSuccessfulInterfaceBoundTailscaleIPv6Write() throws {
    let request = try tailscaleRequest(host: "fd7a:115c:a1e0::1234")
    let snapshot = authoritySnapshot(generation: 41)
    let proof = try CmxTailscaleRouteProofValidator().prepare(
        request: request,
        snapshot: snapshot
    )

    try CmxTailscaleRouteProofValidator().validate(
        proof: proof,
        authoritySnapshot: snapshot,
        connectionPath: connectionPath(
            remoteAddress: "fd7a:115c:a1e0::1234"
        )
    )
}

@Test func rejectsConnectionPathOnAnyInterfaceOtherThanRequiredInterface() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let snapshot = authoritySnapshot(generation: 41)
    let proof = try CmxTailscaleRouteProofValidator().prepare(
        request: request,
        snapshot: snapshot
    )
    let replacement = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)
    let substitutedPath = CmxTailscaleConnectionPathSnapshot(
        isSatisfied: true,
        availableInterfaces: [replacement],
        localAddress: CmxTailscaleIPAddress("100.70.231.80"),
        remoteAddress: CmxTailscaleIPAddress("100.71.210.41"),
        remotePort: 58465
    )

    #expect(throws: CmxTailscaleRouteProofError.connectionPathUnavailable) {
        try CmxTailscaleRouteProofValidator().validate(
            proof: proof,
            authoritySnapshot: snapshot,
            connectionPath: substitutedPath
        )
    }
}

@Test func rejectsAmbiguousTailscaleInterfaces() throws {
    let request = try tailscaleRequest(host: "100.71.210.41")
    let second = CmxNetworkInterfaceIdentity(name: "utun5", index: 23)
    let snapshot = CmxTailscaleAuthoritySnapshot(
        generation: 1,
        pathSatisfied: true,
        availableInterfaces: [tailscaleInterface, second],
        systemInterfaces: [
            interface(name: "utun4", index: 22, addresses: ["100.70.231.80"]),
            interface(name: "utun5", index: 23, addresses: ["100.68.1.2"])
        ]
    )

    #expect(throws: CmxTailscaleRouteProofError.ambiguousTailscaleInterfaces) {
        _ = try CmxTailscaleRouteProofValidator().prepare(
            request: request,
            snapshot: snapshot
        )
    }
}

private func tailscaleRequest(
    host: String,
    authorizationMode: CmxTransportAuthorizationMode = .stackBearer
) throws -> CmxByteTransportRequest {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: host, port: 58465)
    )
    return CmxByteTransportRequest(
        route: route,
        expectedPeerDeviceID: "mac-1",
        authorizationMode: authorizationMode
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
    remoteAddress: String = "100.71.210.41"
) -> CmxTailscaleConnectionPathSnapshot {
    CmxTailscaleConnectionPathSnapshot(
        isSatisfied: true,
        availableInterfaces: [tailscaleInterface],
        localAddress: CmxTailscaleIPAddress("100.70.231.80"),
        remoteAddress: CmxTailscaleIPAddress(remoteAddress),
        remotePort: 58465
    )
}

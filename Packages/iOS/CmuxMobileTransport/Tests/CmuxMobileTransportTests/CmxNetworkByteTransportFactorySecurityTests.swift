import CMUXMobileCore
import Network
import Testing
@testable import CmuxMobileTransport

private enum RejectingTailscaleAuthorityError: Error {
    case rejected
}

private actor RejectingTailscaleAuthority: CmxTailscaleRouteAuthorizing {
    private(set) var preparationCount = 0

    func prepare(
        request _: CmxByteTransportRequest
    ) throws -> CmxPreparedTailscaleRoute {
        preparationCount += 1
        throw RejectingTailscaleAuthorityError.rejected
    }

    func validate(
        proof _: CmxTailscaleRouteProof,
        connectionPath _: NWPath
    ) throws {
        throw RejectingTailscaleAuthorityError.rejected
    }
}

@Suite struct CmxTransportFactorySecurityTests {
    @Test func buildsLoopbackTransportWithExplicitAuthorizationIntent() throws {
        let route = try CmxAttachRoute(
            id: "loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )

        let transport = try CmxNetworkByteTransportFactory().makeTransport(for: request)

        #expect(transport is CmxNetworkByteTransport)
    }

    @Test func rejectsTailscaleRouteWithoutAuthorizationIntent() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )

        #expect(throws: (any Error).self) {
            _ = try CmxNetworkByteTransportFactory().makeTransport(for: route)
        }
        #expect(throws: CmxNetworkByteTransportError.authorizationIntentRequired) {
            _ = try CmxNetworkByteTransport(route: route)
        }
    }

    @Test func rejectsRouteKindAuthorizationSubstitution() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .transportAdmission
        )

        #expect(throws: (any Error).self) {
            _ = try CmxNetworkByteTransportFactory().makeTransport(for: request)
        }
    }

    @Test func rejectsMagicDNSBeforeDial() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "work-mac.tailnet.ts.net", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )

        #expect(throws: (any Error).self) {
            _ = try CmxNetworkByteTransportFactory().makeTransport(for: request)
        }
    }

    @Test func rejectsTailscaleBearerWhenOnlyPacketTunnelHeuristicsAreAvailable() async throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )
        let factory = CmxNetworkByteTransportFactory()

        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: request)
        }
    }

    @Test func preparesExactGrandfatheredTailscaleGrantAtConnectBoundary() async throws {
        let request = try legacyTailscaleRequest()
        let authority = RejectingTailscaleAuthority()
        let factory = CmxNetworkByteTransportFactory(
            tailscaleRouteAuthority: authority
        )

        let transport = try factory.makeTransport(for: request)
        #expect(transport is CmxPreparingTailscaleByteTransport)
        #expect(await authority.preparationCount == 0)

        await #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            try await transport.connect()
        }
        #expect(await authority.preparationCount == 1)
    }

    @Test func rejectsEveryGrandfatheredGrantSubstitutionBeforeDial() throws {
        let validRequest = try legacyTailscaleRequest()
        let validEvidence = try CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "mac-1",
            host: "100.71.210.41",
            port: 58_465
        )
        let factory = CmxNetworkByteTransportFactory()

        let deviceSubstitution = CmxByteTransportRequest(
            route: validRequest.route,
            expectedPeerDeviceID: "mac-2",
            authorizationMode: .legacyTailscaleBearer(validEvidence)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: deviceSubstitution)
        }

        let hostSubstitution = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.71.210.42", port: 58_465)
            ),
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .legacyTailscaleBearer(validEvidence)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: hostSubstitution)
        }

        let portSubstitution = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.71.210.41", port: 58_466)
            ),
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .legacyTailscaleBearer(validEvidence)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: portSubstitution)
        }
    }
}

private func legacyTailscaleRequest() throws -> CmxByteTransportRequest {
    let host = "100.71.210.41"
    let port = 58_465
    return CmxByteTransportRequest(
        route: try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        ),
        expectedPeerDeviceID: "mac-1",
        authorizationMode: .legacyTailscaleBearer(
            try CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: "mac-1",
                host: host,
                port: port
            )
        )
    )
}

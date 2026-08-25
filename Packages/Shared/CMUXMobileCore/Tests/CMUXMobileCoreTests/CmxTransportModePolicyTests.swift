import CMUXMobileCore
import Foundation
import Testing

@Suite("Transport mode policy")
struct CmxTransportModePolicyTests {
    @Test("pinned modes keep only routes in their transport class")
    func pinnedRoutesAreStrict() throws {
        let routes = [
            try route(id: "lan", kind: .lan, host: "192.168.1.10"),
            try route(id: "tailscale", kind: .tailscale, host: "100.64.1.10"),
            try irohRoute(),
        ]

        #expect(try CmxTransportModePolicy(.lanOnly).routes(from: routes).map(\.id) == ["iroh"])
        #expect(try CmxTransportModePolicy(.tailscaleOnly).routes(from: routes).map(\.id) == ["tailscale"])
        #expect(try CmxTransportModePolicy(.irohOnly).routes(from: routes).map(\.id) == ["iroh"])
    }

    @Test("a pinned mode reports an actionable no-route error")
    func missingPinnedRouteFailsClosed() throws {
        let routes = [try irohRoute()]
        do {
            _ = try CmxTransportModePolicy(.tailscaleOnly).routes(
                from: routes,
                macDisplayName: "Studio Mac"
            )
            Issue.record("expected a pinned-mode route error")
        } catch let error as CmxTransportModeError {
            guard case let .noRoute(mode, displayName) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(mode == .tailscaleOnly)
            #expect(displayName == "Studio Mac")
            #expect(error.localizedDescription.contains("Tailscale"))
        }
    }

    @Test("LAN Only accepts an encrypted Iroh peer for broker LAN discovery")
    func lanOnlyUsesEncryptedPeerRoute() throws {
        #expect(
            try CmxTransportModePolicy(.lanOnly).routes(from: [try irohRoute()]).map(\.id)
                == ["iroh"]
        )
    }

    @Test("LAN Only fails closed when only raw TCP is available")
    func lanOnlyRequiresEncryptedPeerWhenNoIrohRoute() throws {
        #expect(throws: CmxTransportModeError.self) {
            try CmxTransportModePolicy(.lanOnly).routes(
                from: [try route(id: "lan", kind: .lan, host: "192.168.1.10")]
            )
        }
    }

    @Test("Tailscale mode never admits Iroh paths")
    func tailscaleNeverFallsBackToIroh() throws {
        let hints = try [
            CmxIrohPathHint(
                kind: .directAddress,
                value: "192.168.1.10:58465",
                source: .lan,
                privacyScope: .localNetwork,
                observedAt: Date(),
                expiresAt: Date().addingTimeInterval(300),
                networkProfile: try CmxIrohNetworkProfileKey(
                    source: .lan,
                    profileID: String(repeating: "1", count: 64)
                )
            ),
            CmxIrohPathHint(
                kind: .directAddress,
                value: "100.64.1.10:58465",
                source: .tailscale,
                privacyScope: .privateNetwork,
                observedAt: Date(),
                expiresAt: Date().addingTimeInterval(300),
                networkProfile: try CmxIrohNetworkProfileKey(
                    source: .tailscale,
                    profileID: String(repeating: "2", count: 64)
                )
            ),
        ]
        let endpoint = try CmxAttachEndpoint.peer(
            identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
            pathHints: hints
        )
        let plan = try #require(endpoint.irohDialPlan(
            at: Date(),
            managedRelayURLs: [],
            activeNetworkProfiles: []
        ))
        let filtered = CmxTransportModePolicy(.irohOnly).irohDialPlan(plan)
        #expect(filtered.publicPaths.isEmpty)
        #expect(filtered.privateFallbackPaths.isEmpty)
    }

    @Test("active path formatting preserves class and concrete endpoint")
    func activePathFormatting() {
        #expect(CmxTransportPath.lan(address: "192.168.1.10").displayValue == "LAN · 192.168.1.10")
        #expect(CmxTransportPath.tailscale(address: "100.64.1.10").displayValue == "Tailscale · 100.64.1.10")
        #expect(CmxTransportPath.irohDirect.displayValue == "iroh direct")
        #expect(CmxTransportPath.irohRelay(region: "us-east").displayValue == "iroh relay us-east")
    }

    @Test("the transport request boundary rejects a cross-class route")
    func requestBoundaryRejectsCrossClassRoute() throws {
        let route = try route(id: "tailscale", kind: .tailscale, host: "100.64.1.10")
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac",
            authorizationMode: .stackBearer,
            transportMode: .lanOnly
        )
        do {
            try request.validateTransportMode()
            Issue.record("expected the pinned LAN policy to reject Tailscale")
        } catch let error as CmxTransportModeError {
            #expect(error == .routeClassMismatch(expected: .lan, actual: .tailscale))
        }
    }

    @Test("diagnostic path classes distinguish LAN and Tailscale")
    func diagnosticPathClassesRemainDistinct() {
        #expect(
            CmxTransportPath.lan(address: "192.168.1.10").diagnosticPathKind
                == .lan
        )
        #expect(
            CmxTransportPath.tailscale(address: "100.64.1.10").diagnosticPathKind
                == .tailscale
        )
        #expect(CmxTransportModePolicy(.tailscaleOnly).allows(
            path: .irohRelay(region: "us-east")
        ) == false)
    }

    @Test("LAN Iroh plans retain only LAN private paths")
    func lanIrohPlanKeepsOnlyLANPaths() throws {
        let plan = CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: [])
        try CmxTransportModePolicy(.lanOnly).validate(irohDialPlan: plan)
        let hints = try [
            CmxIrohPathHint(
                kind: .directAddress,
                value: "192.168.1.10:58465",
                source: .lan,
                privacyScope: .localNetwork,
                observedAt: Date(),
                expiresAt: Date().addingTimeInterval(300),
                networkProfile: try CmxIrohNetworkProfileKey(
                    source: .lan,
                    profileID: String(repeating: "3", count: 64)
                )
            ),
            CmxIrohPathHint(
                kind: .directAddress,
                value: "100.64.1.10:58465",
                source: .tailscale,
                privacyScope: .privateNetwork,
                observedAt: Date(),
                expiresAt: Date().addingTimeInterval(300),
                networkProfile: try CmxIrohNetworkProfileKey(
                    source: .tailscale,
                    profileID: String(repeating: "4", count: 64)
                )
            ),
        ]
        let filtered = CmxTransportModePolicy(.lanOnly).irohDialPlan(
            CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: hints)
        )
        #expect(filtered.privateFallbackPaths.map(\.source) == [.lan])
    }

    @Test("Tailscale Only still rejects Iroh session construction")
    func tailscaleModeRejectsIrohSessionConstruction() {
        do {
            try CmxTransportModePolicy(.tailscaleOnly).validate(
                irohDialPlan: CmxIrohDialPlan(publicPaths: [], privateFallbackPaths: [])
            )
            Issue.record("expected Tailscale Only to reject an Iroh session")
        } catch let error as CmxTransportModeError {
            #expect(error == .routeClassMismatch(expected: .tailscale, actual: .iroh))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Direct mode rejects relay paths and only allows direct attribution")
    func directModeIsRelayFree() throws {
        let relay = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example/",
            source: .native,
            privacyScope: .publicInternet
        )
        let relayPlan = CmxIrohDialPlan(
            publicPaths: [relay],
            privateFallbackPaths: []
        )
        let directPolicy = CmxTransportModePolicy(.direct)
        #expect(directPolicy.irohDialPlan(relayPlan).publicPaths.isEmpty)
        #expect(throws: CmxTransportModeError.self) {
            try directPolicy.validate(irohDialPlan: relayPlan)
        }
        let nativeDirect = try CmxIrohPathHint(
            kind: .directAddress,
            value: "203.0.113.10:58465",
            source: .native,
            privacyScope: .publicInternet
        )
        let customDirect = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.10:58465",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            networkProfile: try CmxIrohNetworkProfileKey(
                source: .customVPN,
                profileID: String(repeating: "5", count: 64)
            )
        )
        let mixedDirectPlan = CmxIrohDialPlan(
            publicPaths: [nativeDirect, customDirect],
            privateFallbackPaths: []
        )
        #expect(
            directPolicy.irohDialPlan(mixedDirectPlan).publicPaths.map(\.source)
                == [.customVPN]
        )
        #expect(throws: CmxTransportModeError.self) {
            try directPolicy.validate(irohDialPlan: mixedDirectPlan)
        }
        #expect(
            directPolicy.irohPathHints([nativeDirect, customDirect]).map(\.source)
                == [.customVPN]
        )
        #expect(directPolicy.allows(path: .irohDirect))
        #expect(!directPolicy.allows(path: .irohRelay(region: "us-east")))
    }

    @Test("legacy Direct mode fails closed without an explicit allowlist")
    func directModeRequiresCandidates() throws {
        let request = CmxByteTransportRequest(
            route: try irohRoute(),
            expectedPeerDeviceID: "mac",
            authorizationMode: .transportAdmission,
            transportMode: .direct
        )
        #expect(throws: CmxTransportModeError.self) {
            try request.validateTransportMode()
        }
    }

    private func route(
        id: String,
        kind: CmxAttachTransportKind,
        host: String
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: kind,
            endpoint: .hostPort(host: host, port: 58_465)
        )
    }

    private func irohRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "b", count: 64)),
                pathHints: []
            )
        )
    }
}

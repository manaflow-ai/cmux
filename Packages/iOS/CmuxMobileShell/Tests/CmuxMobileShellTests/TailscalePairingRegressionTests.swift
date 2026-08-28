import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// End-to-end shell coverage for the compatibility Tailscale pairing funnel.
///
/// These tests intentionally drive the same `connectPairingInput` and
/// `connectManualHost` entry points used by the scanner/paste and Add Computer
/// UI.  The scripted host records the transport request and every bearer so a
/// route can be proven to be both selected and authorized before the fix lands.
@MainActor
@Suite struct TailscalePairingRegressionTests {
    private let host = "100.71.210.41"
    private let port = CmxMobileDefaults.defaultHostPort

    @Test func currentQRCodeEnteredThroughSharedInputAuthorizesExactRoute() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Date.now },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let store = makeStore(runtime: runtime)
        store.pairingCode = currentQRCode()

        await store.connectPairingInput()

        #expect(store.connectionState == MobileConnectionState.connected)
        #expect(store.activeRoute?.kind == .tailscale)
        #expect(factory.attemptedAuthorizationModes() == [
            .userAuthorizedTailscalePairing(
                try CmxUserTailscalePairingAuthorization(host: host, port: port)
            ),
        ])
        let requests = await router.authorization(for: "workspace.list")
        #expect(requests.first?.stackAccessToken == "test-stack-token")
    }

    @Test func legacyTokenlessQRCodeEnteredThroughPasteUsesTheSameAuthorization() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Date.now },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)
        // Older Macs encode the same route in the v1 full-key ticket. The
        // payload is tokenless, so the explicit in-app paste is the authority.
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            // Legacy pairing URLs may carry no trusted device id; the host
            // status response supplies the identity after the authenticated
            // route is established.
            macDeviceID: "",
            macDisplayName: "Legacy Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [try tailscaleRoute()],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: nil
        )
        store.pairingCode = try attachURL(for: ticket)

        await store.connectPairingInput()

        #expect(store.connectionState == MobileConnectionState.connected)
        #expect(store.activeRoute?.endpoint == .hostPort(host: host, port: port))
        #expect(factory.attemptedAuthorizationModes() == [
            .userAuthorizedTailscalePairing(
                try CmxUserTailscalePairingAuthorization(host: host, port: port)
            ),
        ])
    }

    @Test func manualNumericEntryAuthorizesExactDestinationAndPersistsRouteGrant() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Date.now },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)

        await store.connectManualHost(name: "Work Mac", host: host, port: port)

        #expect(store.connectionState == MobileConnectionState.connected)
        #expect(store.activeRoute?.kind == .tailscale)
        #expect(factory.attemptedAuthorizationModes() == [
            .userAuthorizedTailscalePairing(
                try CmxUserTailscalePairingAuthorization(host: host, port: port)
            ),
        ])
        #expect((await router.authorization(for: "workspace.list")).first?.stackAccessToken == "test-stack-token")
    }

    @Test func manualMagicDNSHasDeterministicSafeFallbackWithoutDialing() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Date.now },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)

        await store.connectManualHost(
            name: "Work Mac",
            host: "work-mac.tailnet.ts.net",
            port: port
        )

        #expect(store.connectionState == MobileConnectionState.disconnected)
        #expect(store.activeRoute == nil)
        #expect(factory.attemptedAuthorizationModes().isEmpty)
        #expect(store.connectionError?.localizedCaseInsensitiveContains("numeric") == true)
        #expect(await router.count(of: "workspace.list") == 0)
    }

    @Test func arbitraryAndLanManualHostsNeverReceiveAStackBearer() async throws {
        for host in ["192.168.1.77", "10.0.0.5", "example.com"] {
            let router = LivenessHostRouter()
            let box = TransportBox()
            let factory = KindRecordingTransportFactory(router: router, box: box)
            let runtime = LivenessTestRuntime(
                transportFactory: factory,
                now: { Date.now },
                supportedRouteKinds: [.tailscale]
            )
            let store = makeStore(runtime: runtime)

            await store.connectManualHost(name: "Untrusted", host: host, port: port)

            #expect(store.connectionState == MobileConnectionState.disconnected)
            #expect(factory.attemptedAuthorizationModes().isEmpty)
            #expect(await router.authorization(for: "workspace.list").isEmpty)
        }
    }

    @Test func externallyOpenedQRCodeDoesNotMintInAppTailscaleAuthorization() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Date.now },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)

        let result = await store.connectPairingURLResult(currentQRCode())

        #expect(result == .failed)
        #expect(factory.attemptedAuthorizationModes().isEmpty)
        #expect(await router.authorization(for: "workspace.list").isEmpty)
    }

    private func makeStore(runtime: any MobileSyncRuntime) -> MobileShellComposite {
        MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "tailscale-pairing-regression-\(UUID().uuidString)"
            )!
        )
    }

    private func currentQRCode() -> String {
        "cmux-ios://attach?v=2&pc=1&r=\(host):\(port)"
    }

    private func tailscaleRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: 10
        )
    }
}

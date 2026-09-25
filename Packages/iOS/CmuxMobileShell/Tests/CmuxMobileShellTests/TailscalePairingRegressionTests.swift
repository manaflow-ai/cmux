import CMUXMobileCore
import CmuxMobilePairedMac
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
    private nonisolated static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private let host = "100.71.210.41"
    private let port = CmxMobileDefaults.defaultHostPort

    @Test(arguments: MobileConnectionMethod.allCases)
    func currentQRCodeEnteredThroughSharedInputAuthorizesExactRoute(
        _ method: MobileConnectionMethod
    ) async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await pairedMacStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscaleRoute()],
            instanceTag: "default",
            markActive: true,
            stackUserID: "phone-user",
            now: Self.fixedNow
        )
        try await pairedMacStore.setConnectionMethod(
            macDeviceID: "test-mac",
            instanceTag: "default",
            rawValue: method.rawValue,
            stackUserID: "phone-user"
        )
        let store = makeStore(runtime: runtime, pairedMacStore: pairedMacStore)
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

    /// A current Mac's Tailscale code also names its device key, so the
    /// entered code dials Direct QUIC pinned to exactly that Tailscale
    /// endpoint, authenticated by the key rather than a Stack bearer on raw TCP.
    @Test func codeNamingTheMacDeviceKeyDialsDirectQuicToTheAuthorizedEndpoint() async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "default", displayName: "Test Mac")
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let store = makeStore(runtime: runtime)
        store.pairingCode = currentQRCode()
            + "&i=\(String(repeating: "a", count: 64))&d=test-mac"

        await store.connectPairingInput()

        #expect(store.connectionState == MobileConnectionState.connected)
        #expect(store.activeRoute?.kind == .iroh)
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(factory.attemptedAuthorizationModes() == [.transportAdmission])
        #expect(factory.attemptedPins() == [
            [CmxIrohDirectDialCandidate(address: host, port: UInt16(port))],
        ])
    }

    /// Entering such a code saves its Tailscale endpoint as one of the
    /// Computer's Direct addresses instead of a raw-TCP grant.
    @Test func codeNamingTheMacDeviceKeySavesTheTailscaleEndpointAsADirectAddress() async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "default", displayName: "Test Mac")
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let store = makeStore(
            runtime: LivenessTestRuntime(
                transportFactory: factory, now: { Self.fixedNow }, supportedRouteKinds: [.iroh, .tailscale]
            ),
            pairedMacStore: pairedMacStore
        )
        store.pairingCode = currentQRCode()
            + "&i=\(String(repeating: "a", count: 64))&d=test-mac"

        await store.connectPairingInput()

        #expect(store.connectionState == MobileConnectionState.connected)
        let saved = try #require(try await pairedMacStore.activeMac(stackUserID: "phone-user"))
        #expect(saved.directAddresses == [
            MobilePairedMacDirectAddress(address: host, port: port, label: "Tailscale"),
        ])
        #expect(saved.legacyTailscaleRoutes == nil)
    }

    @Test func replacementScanCanExplicitlyAuthorizeTailscaleForDirectMac() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await pairedMacStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try tailscaleRoute()],
            instanceTag: "default",
            markActive: true,
            stackUserID: "phone-user",
            now: Self.fixedNow
        )
        try await pairedMacStore.setConnectionMethod(
            macDeviceID: "test-mac",
            instanceTag: "default",
            rawValue: MobileConnectionMethod.direct.rawValue,
            stackUserID: "phone-user"
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
            supportedRouteKinds: [.iroh, .tailscale]
        )
        let store = makeStore(
            runtime: runtime,
            pairedMacStore: pairedMacStore
        )
        store.pairingCode = currentQRCode()

        let result = await store.connectPairingInput(
            allowPreview: false,
            pairedMacDeviceID: "test-mac",
            instanceTag: "default"
        )

        #expect(result == .connected)
        #expect(store.activeRoute?.kind == .tailscale)
    }

    @Test func legacyTokenlessQRCodeEnteredThroughPasteUsesTheSameAuthorization() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
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
            expiresAt: Self.fixedNow.addingTimeInterval(3600),
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

    @Test func manualNumericEntryAuthorizesExactDestination() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
            supportedRouteKinds: [.tailscale],
            supportsServerPushEvents: false
        )
        let store = makeStore(runtime: runtime, pairedMacStore: pairedMacStore)

        await store.connectManualHost(name: "Work Mac", host: host, port: port)

        #expect(store.connectionState == MobileConnectionState.connected)
        #expect(store.activeRoute?.kind == .tailscale)
        #expect(factory.attemptedAuthorizationModes() == [
            .userAuthorizedTailscalePairing(
                try CmxUserTailscalePairingAuthorization(host: host, port: port)
            ),
        ])
        #expect((await router.authorization(for: "workspace.list")).first?.stackAccessToken == "test-stack-token")
        let saved = try await pairedMacStore.activeMac(stackUserID: "phone-user")
        #expect(saved?.legacyTailscaleRoutes?.first?.endpoint == .hostPort(host: host, port: port))
    }

    @Test func rescanningQRCodeRestoresDeletedRouteInTheComputerList() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let originalRoute = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: 10
        )
        let irohRoute = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            ),
            priority: 0
        )
        let debugRoute = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 20
        )
        try await pairedMacStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [irohRoute, originalRoute, debugRoute],
            instanceTag: "default",
            markActive: true,
            stackUserID: "phone-user",
            now: Self.fixedNow
        )
        try await pairedMacStore.setConnectionMethod(
            macDeviceID: "test-mac",
            instanceTag: "default",
            rawValue: MobileConnectionMethod.direct.rawValue,
            stackUserID: "phone-user"
        )
        #expect(try await pairedMacStore.removeRouteIfAuthorized(
            macDeviceID: "test-mac",
            route: originalRoute,
            condition: .matchingInstanceTag("default"),
            stackUserID: "phone-user",
            teamID: nil,
            now: Self.fixedNow.addingTimeInterval(1)
        ))

        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
            supportedRouteKinds: [.iroh, .tailscale, .debugLoopback]
        )
        let store = makeStore(
            runtime: runtime,
            pairedMacStore: pairedMacStore
        )
        store.pairingCode = currentQRCode()

        await store.connectPairingInput()

        let saved = try #require(await pairedMacStore.activeMac(stackUserID: "phone-user"))
        #expect(saved.routes.contains(originalRoute))
        #expect(saved.routes.contains(irohRoute))
        #expect(saved.routes.contains(debugRoute))
        let displayed = try #require(store.displayPairedMacs.first { $0.macDeviceID == "test-mac" })
        #expect(displayed.routes.contains(originalRoute))
    }

    @Test func manualMagicDNSHasDeterministicSafeFallbackWithoutDialing() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
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
                now: { Self.fixedNow },
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
            now: { Self.fixedNow },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)

        let result = await store.connectPairingURLResult(currentQRCode())

        #expect(result == .failed)
        #expect(factory.attemptedAuthorizationModes().isEmpty)
        #expect(await router.authorization(for: "workspace.list").isEmpty)
    }

    @Test func scannerInputRejectsNonPairingPayload() async throws {
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox()
            ),
            now: { Self.fixedNow },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)
        store.pairingCode = "https://example.com/not-a-cmux-pairing-code"

        let result = await store.connectPairingInput(allowPreview: false)

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
    }

    @Test func invalidScannerPayloadDoesNotClearConnectedSession() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { Self.fixedNow },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)
        store.pairingCode = currentQRCode()
        #expect(await store.connectPairingInput() == .connected)
        let connectedRoute = store.activeRoute

        store.pairingCode = "https://example.com/not-a-cmux-pairing-code"
        #expect(await store.connectPairingInput(allowPreview: false) == .failed)
        #expect(store.connectionState == .connected)
        #expect(store.activeRoute == connectedRoute)
    }

    @Test func replacementPairingRejectsDifferentMacIdentity() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { Self.fixedNow },
            supportedRouteKinds: [.tailscale]
        )
        let store = makeStore(runtime: runtime)
        store.pairingCode = currentQRCode()

        let result = await store.connectPairingInput(
            allowPreview: false,
            pairedMacDeviceID: "another-mac"
        )

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
    }

    private func makeStore(
        runtime: any MobileSyncRuntime,
        pairedMacStore: (any MobilePairedMacStoring)? = nil
    ) -> MobileShellComposite {
        return MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
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

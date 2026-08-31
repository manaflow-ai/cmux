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
        let store = makeStore(runtime: runtime, connectionMethod: method)
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
        #expect(saved?.connectionMethodRawValue == MobileConnectionMethod.tailscale.rawValue)
    }

    @Test(arguments: [
        "work-mac.tailnet.ts.net",
        "work-mac",
        "192.168.1.77",
    ])
    func manualNamedAndLanHostsPairAndPersistTailscaleMethod(_ manualHost: String) async throws {
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

        await store.connectManualHost(
            name: "Work Mac",
            host: manualHost,
            port: port
        )

        #expect(store.connectionState == MobileConnectionState.connected)
        #expect(store.activeRoute?.endpoint == .hostPort(host: manualHost, port: port))
        #expect(factory.attemptedAuthorizationModes().count == 1)
        let saved = try #require(await pairedMacStore.activeMac(stackUserID: "phone-user"))
        #expect(saved.connectionMethodRawValue == MobileConnectionMethod.tailscale.rawValue)
        #expect(saved.legacyTailscaleRoutes?.first?.endpoint == .hostPort(host: manualHost, port: port))

        // Reload from the SQLite row and prove the exact user grant, rather
        // than the app default, selects the same route on the next launch.
        await store.remoteClient?.disconnect()
        let reconnectFactory = KindRecordingTransportFactory(
            router: router,
            box: TransportBox()
        )
        let reloaded = makeStore(
            runtime: LivenessTestRuntime(
                transportFactory: reconnectFactory,
                now: { Self.fixedNow },
                supportedRouteKinds: [.tailscale],
                supportsServerPushEvents: false
            ),
            pairedMacStore: pairedMacStore
        )
        #expect(await reloaded.reconnectActiveMacIfAvailable(stackUserID: "phone-user"))
        #expect(reloaded.activeRoute?.endpoint == .hostPort(host: manualHost, port: port))
        #expect(reconnectFactory.attemptedAuthorizationModes() == [
            .userAuthorizedTailscalePairing(
                try CmxUserTailscalePairingAuthorization(host: manualHost, port: port)
            ),
        ])
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

    @Test func secondQRCodePairingSucceedsWhileFirstConnectionRemainsLive() async throws {
        let router = LivenessHostRouter()
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

        await router.setHostIdentity(deviceID: "first-mac", instanceTag: "default")
        store.pairingCode = qrCode(host: "100.71.210.41")
        #expect(await store.connectPairingInput() == .connected)
        #expect(store.connectionState == .connected)

        // The second add starts with the same `.connected` state. Its result,
        // not a state edge, is what the sheet uses to dismiss.
        await router.setHostIdentity(deviceID: "second-mac", instanceTag: "default")
        store.pairingCode = qrCode(host: "100.71.210.42")
        #expect(await store.connectPairingInput() == .connected)
        #expect(store.connectionState == .connected)

        let saved = try await pairedMacStore.loadAll(stackUserID: "phone-user")
        #expect(Set(saved.map(\.macDeviceID)) == ["first-mac", "second-mac"])
        #expect(Set(saved.map(\.instanceTag)) == ["default"])
        #expect(saved.allSatisfy { $0.connectionMethodRawValue == MobileConnectionMethod.tailscale.rawValue })
    }

    private func makeStore(
        runtime: any MobileSyncRuntime,
        pairedMacStore: (any MobilePairedMacStoring)? = nil,
        connectionMethod: MobileConnectionMethod? = nil
    ) -> MobileShellComposite {
        let methodStore: MobileConnectionMethodStore? = connectionMethod.map { method in
            let defaults = UserDefaults(
                suiteName: "tailscale-pairing-regression-method-\(UUID().uuidString)"
            )!
            let store = MobileConnectionMethodStore(defaults: defaults)
            store.method = method
            return store
        }
        return MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            connectionMethodStore: methodStore,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "tailscale-pairing-regression-\(UUID().uuidString)"
            )!
        )
    }

    private func currentQRCode() -> String {
        qrCode(host: host)
    }

    private func qrCode(host: String) -> String {
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

import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct SecondaryRouteFallbackTests {
    @Test func secondaryAggregationSkipsTailscaleAndUsesApprovedManualHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let tailscaleRoute = try CmxAttachRoute(
            id: "preferred-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50_922),
            priority: 0
        )
        let manualRoute = try CmxAttachRoute(
            id: "approved-manual-host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 50_923),
            priority: 10
        )
        try await pairedMacStore.upsert(
            macDeviceID: "secondary-mac",
            displayName: "Secondary Mac",
            routes: [tailscaleRoute, manualRoute],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let trustStore = InMemoryMobileManualHostTrustStore()
        let trustScope = try #require(
            MobileManualHostTrustScope(route: manualRoute, stackUserID: "phone-user")
        )
        await trustStore.trust(trustScope)
        let attempts = RouteAttemptRecorder()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "secondary-mac", instanceTag: nil, displayName: "Secondary Mac")
        let runtime = LivenessTestRuntime(
            transportFactory: SecondaryRouteFallbackTransportFactory(
                router: router,
                box: TransportBox(),
                attempts: attempts
            ),
            now: { Date() },
            supportedRouteKinds: [.tailscale, .manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: trustStore
        )
        await store.loadPairedMacs()

        await store.refreshSecondaryMacWorkspaces()

        #expect(attempts.count(.tailscale) == 0)
        #expect(attempts.count(.manualHost) >= 1)
        #expect(store.secondaryMacSubscriptions["secondary-mac"]?.route.kind == .manualHost)
    }
}

import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct SecondaryManualHostTrustExpirationTests {
    @Test func expiredTrustDisconnectsLiveSecondaryWithoutAnotherRPC() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let manualRoute = try CmxAttachRoute(
            id: "expiring-secondary-manual-host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.88", port: 50_923)
        )
        try await pairedMacStore.upsert(
            macDeviceID: "secondary-mac",
            displayName: "Secondary Mac",
            routes: [manualRoute],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let attempts = RouteAttemptRecorder()
        let runtime = LivenessTestRuntime(
            transportFactory: SecondaryRouteFallbackTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox(),
                attempts: attempts
            ),
            now: { Date() },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: ImmediateExpiryManualHostTrustStore()
        )

        await store.loadPairedMacs()
        await store.refreshSecondaryMacWorkspaces()
        let expired = try await pollUntil(attempts: 50) {
            store.secondaryMacSubscriptions["secondary-mac"] == nil
        }

        #expect(attempts.count(.manualHost) >= 1)
        #expect(expired)
        #expect(store.secondaryMacSubscriptions["secondary-mac"] == nil)
    }
}

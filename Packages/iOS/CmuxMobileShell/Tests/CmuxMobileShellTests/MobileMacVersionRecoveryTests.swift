import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileMacVersionRecoveryTests {
    @Test(arguments: [false, true])
    func pooledUpdatedMacUsesAuthenticatedVersionWhenPromoted(useFastFocus: Bool) async throws {
        let defaultsName = "mobile-version-promotion-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("pairings.sqlite3"))
        let route = try CmxAttachRoute(
            id: "version-recovery",
            kind: .iroh,
            endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: [])
        )
        try await pairedStore.upsert(
            macDeviceID: "test-mac", displayName: "Test Mac", routes: [route],
            instanceTag: "default", markActive: true, stackUserID: "user-1"
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "test-mac", instanceTag: "default", clientNamespace: "mac:com.cmuxterm.app")
        await router.setMacAppVersion("0.64.22")
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() }, supportedRouteKinds: [.iroh]
        )
        let shell = MobileShellComposite(
            runtime: runtime, isSignedIn: true, pairedMacStore: pairedStore,
            buildCompatibilityPolicy: .official,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(), pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults,
            feedbackStampProvider: {
                MobileFeedbackStamp(buildType: .beta, appVersion: "1.0.5", appBuild: "1",
                                    bundleIdentifier: "dev.cmux.app.beta", osVersion: "test", deviceModel: "test")
            }
        )
        await shell.loadPairedMacs()
        let oldTicket = try CmxAttachTicket(
            workspaceID: "live-workspace", terminalID: nil, macDeviceID: "test-mac", macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            macAppVersion: "0.64.22", routes: [route], expiresAt: nil
        )
        #expect(!(await shell.connectPairingURL(try attachURL(for: oldTicket))))
        #expect(shell.hasMacVersionUpdateRequired)
        await router.setMacAppVersion("0.64.25")
        let mac = try #require(await pairedStore.activeMac(stackUserID: "user-1"))
        let scope = MobileShellScopeSnapshot(userID: "user-1", teamID: nil, generation: 0)
        guard case .connected = await shell.establishSecondaryMacSubscription(
            for: mac, scope: scope, authorityValidation: .store, persistAuthenticatedDiscovery: true
        ) else {
            Issue.record("Updated Mac must establish its authenticated control connection")
            return
        }
        let subscription = try #require(shell.secondaryMacSubscriptions[MacPairingKey(mac)])
        let attemptID = UUID()
        shell.macSwitchAttemptID = attemptID
        shell.macSwitchAttemptSignInGeneration = shell.signInGeneration
        if useFastFocus {
            #expect(shell.focusWarmIrohPeer(subscription.ownerKey, switchAttemptID: attemptID))
            shell.revalidateActiveMacCompatibilityPolicy()
        } else {
            #expect(await shell.promoteSecondaryToForeground(subscription.ownerKey, switchAttemptID: attemptID))
        }
        #expect(shell.connectionState == .connected)
        #expect(!shell.hasMacVersionUpdateRequired)
        #expect(shell.connectionError == nil)
        shell.disconnectLiveConnection()
    }

    @Test func reconnectRechecksUpdatedMacOnTheSameRoute() async throws {
        let defaultsName = "mobile-version-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "default",
            clientNamespace: "mac:com.cmuxterm.app"
        )
        await router.setMacAppVersion("0.64.22")
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() }
        )
        let shell = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            buildCompatibilityPolicy: .official,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults,
            feedbackStampProvider: {
                MobileFeedbackStamp(
                    buildType: .beta,
                    appVersion: "1.0.5",
                    appBuild: "1",
                    bundleIdentifier: "dev.cmux.app.beta",
                    osVersion: "test",
                    deviceModel: "test"
                )
            }
        )
        let ticket = try makeTicket(clock: TestClock(), macAppVersion: "0.64.22")
        let url = try attachURL(for: ticket)
        #expect(!(await shell.connectPairingURL(url)))
        #expect(shell.hasMacVersionUpdateRequired)
        #expect(shell.connectionError?.contains("0.64.23") == true)

        await router.setMacAppVersion("0.64.25")
        #expect(await shell.connectPairingURL(url))
        #expect(shell.connectionState == .connected)
        #expect(!shell.hasMacVersionUpdateRequired)
        #expect(shell.connectionError == nil)
        shell.disconnectLiveConnection()
    }
}

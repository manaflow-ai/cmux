import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellAuthScopeIsolationTests {
    @Test func accountSwitchDuringDirectSecondaryRefreshNeverSendsNewTokenToOldManualHost() async throws {
        try await assertSessionChangeNeverSendsNewToken(
            replacementUserID: "user-b",
            replacementToken: "user-b-token"
        )
    }

    @Test func sameAccountSignOutAndSignInInvalidatesOldSecondaryRefresh() async throws {
        try await assertSessionChangeNeverSendsNewToken(
            replacementUserID: "user-a",
            replacementToken: "new-user-a-session-token"
        )
    }

    private func assertSessionChangeNeverSendsNewToken(
        replacementUserID: String,
        replacementToken: String
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "manual-host-a",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465)
        )
        try await pairedMacStore.upsert(
            macDeviceID: "user-a-mac",
            displayName: "User A Mac",
            routes: [route],
            markActive: false,
            stackUserID: "user-a",
            teamID: nil,
            now: Date()
        )
        let trustStore = InMemoryMobileManualHostTrustStore()
        let trustScope = try #require(MobileManualHostTrustScope(route: route, stackUserID: "user-a"))
        await trustStore.trust(trustScope)
        let tokenProvider = BlockingAccountSwitchTokenProvider()
        let tokenSink = RecordedAuthTokenSink()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: RecordedAuthLivenessTransportFactory(
                router: router,
                tokenSink: tokenSink
            ),
            stackAccessTokenProvider: { try await tokenProvider.tokenIgnoringCancellation() },
            now: { Date() },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let identity = StaticIdentityProvider(userID: "user-a")
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            pairedMacStore: pairedMacStore,
            identityProvider: identity,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "auth-scope-pairing-\(UUID().uuidString)")!,
            multiMacAggregationDefaults: UserDefaults(suiteName: "auth-scope-aggregation-\(UUID().uuidString)")!,
            manualHostTrustStore: trustStore
        )
        store.signIn()

        let refresh = Task { @MainActor in
            await store.refreshSecondaryMacWorkspaces()
        }
        await tokenProvider.waitUntilRequested()
        store.signOut()
        identity.currentUserID = replacementUserID
        store.signIn()
        await tokenProvider.release(with: replacementToken)
        await refresh.value

        #expect(await tokenSink.recordedTokens().isEmpty)
        #expect(store.secondaryMacSubscriptions["user-a-mac"] == nil)
    }
}

import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellAuthScopeIsolationTests {
    @Test func manualHostApprovalFailsClosedWithoutConcreteAccount() async {
        let store = MobileShellComposite(
            runtime: PairingDeadlineRuntime(supportedRouteKinds: [.manualHost]),
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: nil),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "nil-auth-scope-\(UUID().uuidString)")!
        )

        let result = await store.connectManualHost(
            name: "LAN Mac",
            host: "192.168.1.77",
            port: 58_465
        )

        #expect(result == .failed)
        #expect(store.manualHostTrustWarning == nil)
        #expect(store.connectionRequiresReauth)
    }

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

    @Test func authenticatedUserReplacementNeverSharesPreviousAccountsTokenTask() async throws {
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
            id: "shared-manual-host",
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
        let trustStore = SignalingManualHostTrustStore()
        let userAScope = try #require(
            MobileManualHostTrustScope(route: route, stackUserID: "user-a")
        )
        let userBScope = try #require(
            MobileManualHostTrustScope(route: route, stackUserID: "user-b")
        )
        await trustStore.trust(userAScope)
        await trustStore.trust(userBScope)
        let tokenProvider = AccountReplacementTokenProvider()
        let tokenSink = RecordedAuthTokenSink()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: RecordedAuthLivenessTransportFactory(
                router: router,
                tokenSink: tokenSink
            ),
            stackAccessTokenProvider: { try await tokenProvider.token() },
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
            pairingHintDefaults: UserDefaults(suiteName: "replacement-pairing-\(UUID().uuidString)")!,
            multiMacAggregationDefaults: UserDefaults(suiteName: "replacement-aggregation-\(UUID().uuidString)")!,
            manualHostTrustStore: trustStore
        )
        store.signIn()

        let oldAccountRefresh = Task { @MainActor in
            await store.refreshSecondaryMacWorkspaces()
        }
        await tokenProvider.waitUntilRequestCount(1)

        identity.currentUserID = "user-b"
        store.signIn()
        let replacementConnect = Task { @MainActor in
            await store.connectManualHost(
                name: "User B Mac",
                host: "192.168.1.77",
                port: 58_465
            )
        }
        await trustStore.waitUntilChecked(userBScope, count: 3)
        for _ in 0..<1_000 { await Task.yield() }

        await tokenProvider.releaseRequest(1, with: "user-a-token")
        for _ in 0..<1_000 {
            if await tokenProvider.currentRequestCount() >= 2 { break }
            if await tokenSink.recordedTokens().contains("user-a-token") { break }
            await Task.yield()
        }
        #expect(await tokenProvider.currentRequestCount() == 2)
        await tokenProvider.releaseRequest(2, with: "user-b-token")
        _ = await replacementConnect.value
        await oldAccountRefresh.value

        #expect(!(await tokenSink.recordedTokens().contains("user-a-token")))
        #expect(await tokenSink.recordedTokens().contains("user-b-token"))
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

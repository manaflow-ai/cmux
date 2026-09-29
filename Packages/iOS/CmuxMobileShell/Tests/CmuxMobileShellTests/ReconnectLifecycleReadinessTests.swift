import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func readinessLossPreservesExplicitRecoveryIntent() {
        let shell = MobileShellComposite(pairingHintDefaults: UserDefaults(suiteName: "intent-\(UUID())")!)
        shell.pendingInactiveRecoveryTrigger = .connectionMethodChanged
        shell.connectionReadinessDidChange(false)
        if case .some(.connectionMethodChanged) = shell.pendingInactiveRecoveryTrigger {} else {
            Issue.record("Readiness must preserve a parked method change")
        }
        shell.pendingInactiveRecoveryTrigger = .manual
        shell.connectionReadinessDidChange(false)
        if case .some(.manual) = shell.pendingInactiveRecoveryTrigger {} else {
            Issue.record("Readiness must preserve a parked explicit retry")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func foregroundDuringCancellationRetainsTheRecoveryTrigger() async throws {
        let pairedStore = DelayedTeamPairedMacStore(recordsByTeam: ["": []], blockedTeams: [""])
        let counts = await pairedStore.loadCounts()
        let factory = KindRecordingTransportFactory(router: LivenessHostRouter(), box: TransportBox())
        let runtime = LivenessTestRuntime(transportFactory: factory, now: Date.init, supportedRouteKinds: [.iroh])
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true, pairedMacStore: pairedStore,
                                        identityProvider: StaticIdentityProvider(userID: "user-1"),
                                        reachability: AlwaysOnlineReachability(),
                                        pairingHintDefaults: UserDefaults(suiteName: "lifecycle-race-\(UUID())")!)
        let first = Task { await shell.reconnectActiveMacOutcome(stackUserID: "user-1") }
        await pairedStore.waitUntilLoadStarted(teamID: nil)
        let oldGeneration = shell.storedMacReconnectGeneration
        // No suspension between these transitions: cancellation cannot finish first.
        shell.suspendForegroundRefresh()
        shell.resumeForegroundRefresh()
        #expect(shell.pendingInactiveRecoveryTrigger != nil)
        _ = await first.value
        let nextRead = Task<Bool, any Error> {
            for await count in counts where count >= 2 { return true }
            return false
        }
        defer { nextRead.cancel() }
        let resumed = try? await RPCTaskTimeout().value(nextRead, timeoutNanoseconds: 2_000_000_000)
        #expect(resumed == true, "foreground intent must replay after the retiring owner settles")
        #expect(shell.storedMacReconnectGeneration > oldGeneration)
        let pending = shell.storedMacReconnectDeadlineTask
        shell.suspendForegroundRefresh()
        _ = await pending?.value
        await pairedStore.release(teamID: nil)
    }

    @Test func blockedLifecycleParksReconnectWithoutDialOrBackoff() async throws {
        let readiness = TestMobileConnectionReadiness(permitsConnection: false)
        let router = LivenessHostRouter()
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let runtime = LivenessTestRuntime(connectionReadiness: readiness,
                                         transportFactory: factory, now: Date.init, supportedRouteKinds: [.iroh])
        let shell = try await makeReconnectStore(routes: [try iroh()], runtime: runtime)
        let outcome = await shell.reconnectActiveMacOutcome(stackUserID: "user-1")
        if case .failed(.cancelled) = outcome {} else { Issue.record("Lifecycle deferral must be classified as cancellation") }
        #expect(factory.attemptedKinds().isEmpty)
        #expect(!shell.isReconnectingStoredMac)
        #expect(shell.pendingInactiveRecoveryTrigger != nil)
        #expect(shell.automaticReconnectBackoffOwner.transientRetryAt == nil)
        // Exercise the next admitted attempt before releasing any stale work.
        readiness.permitsConnection = true
        #expect(await shell.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(factory.attemptedKinds() == [.iroh])
        await shell.remoteClient?.disconnect()
    }

    @Test func backgroundLifecycleBlocksEvenAnExplicitStoredReconnect() async throws {
        let router = LivenessHostRouter()
        let factory = KindRecordingTransportFactory(router: router, box: TransportBox())
        let runtime = LivenessTestRuntime(transportFactory: factory, now: Date.init, supportedRouteKinds: [.iroh])
        let shell = try await makeReconnectStore(routes: [try iroh()], runtime: runtime)
        shell.suspendForegroundRefresh()
        let outcome = await shell.reconnectActiveMacOutcome(stackUserID: "user-1", force: true)
        if case .failed(.cancelled) = outcome {} else { Issue.record("A background reconnect must defer without a network failure") }
        #expect(factory.attemptedKinds().isEmpty)
        #expect(!shell.isReconnectingStoredMac)
        #expect(shell.automaticReconnectBackoffOwner.transientRetryAt == nil)
    }
}

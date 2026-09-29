import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct ReconnectOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func forcedRetrySurvivesRetirement(background: Bool) async throws {
        let pairedStore = DelayedTeamPairedMacStore(recordsByTeam: ["": []], blockedTeams: [""])
        let counts = await pairedStore.loadCounts()
        let clock = ReconnectDeadlineGate()
        var runtime = LivenessTestRuntime(
            transportFactory: KindRecordingTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
            now: Date.init, supportedRouteKinds: [.iroh])
        runtime.reconnectDeadlineGate = clock
        let shell = MobileShellComposite(
            runtime: runtime, isSignedIn: true, pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"), reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "forced-retirement-\(UUID())")!,
            storedMacReconnectRestoringDeadlineSeconds: 3600)
        let first = Task { await shell.reconnectActiveMacOutcome(stackUserID: "user-1") }
        await pairedStore.waitUntilLoadStarted(teamID: nil)
        await clock.waitUntilArmed()
        #expect(!(await shell.retryActiveMacReconnect(stackUserID: "user-1", force: true)))
        #expect(shell.pendingForcedStoredMacReconnect)
        if background { shell.suspendForegroundRefresh() } else { clock.expirePending() }
        #expect(await first.value == .failed(background ? .cancelled : .timedOut))
        if background {
            #expect(shell.pendingForcedStoredMacReconnect)
            shell.resumeForegroundRefresh()
        }
        let secondStarted = Task<Bool, any Error> {
            for await count in counts where count >= 2 { return true }
            return false
        }
        defer { secondStarted.cancel() }
        let observed = try? await RPCTaskTimeout().value(secondStarted, timeoutNanoseconds: 10_000_000_000)
        #expect(observed == true, "the queued forced retry must acquire the new generation")
        #expect(!shell.pendingForcedStoredMacReconnect)
        let pending = shell.storedMacReconnectDeadlineTask
        shell.suspendForegroundRefresh()
        _ = await pending?.value
        await pairedStore.release(teamID: nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func zeroTouchCandidateCannotReviveAnOwnerAcrossReadinessLoss() async throws {
        let mac = try macDialCandidate(deviceID: "late-discovery", endpointByte: "a")
        let fixture = try await MacDialFixture.make(macs: [mac], discovered: [mac])
        defer { fixture.cleanup() }
        let router = try fixture.router(for: mac)
        await router.delayHostStatusRequest(number: 1)
        let first = Task { await fixture.shell.reconnectActiveMacOutcome(stackUserID: "user-1") }
        #expect(await router.waitForCount(of: "mobile.host.status", atLeast: 1))
        let scope = try #require(await fixture.shell.currentScopeSnapshot(userID: "user-1"))
        let generation = fixture.shell.storedMacReconnectGeneration
        let deadline = try #require(fixture.shell.storedMacReconnectDeadlineTask)
        #expect(fixture.shell.reconnectAttemptIsCurrent(generation: generation, scope: scope))
        fixture.shell.suspendForegroundRefresh()
        fixture.shell.resumeForegroundRefresh()
        // No cancellation task has had an actor turn yet. Readiness is restored,
        // but the previous owner must already be permanently unable to adopt.
        #expect(!fixture.shell.reconnectAttemptIsCurrent(generation: generation, scope: scope))
        fixture.shell.suspendForegroundRefresh()
        #expect(await first.value == .failed(.cancelled))
        await router.releaseAllHeld()
        if let abandoned = await deadline.value.abandoned { _ = await abandoned.value }
        #expect(fixture.shell.remoteClient == nil)
        #expect(fixture.shell.connectionState != .connected)
        #expect(try await fixture.store.loadAll(stackUserID: "user-1", teamID: nil).isEmpty)
    }
}

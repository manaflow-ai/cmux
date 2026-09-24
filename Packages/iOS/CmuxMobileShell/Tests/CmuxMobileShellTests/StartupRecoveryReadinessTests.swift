import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Launch-window regression coverage: the window BEFORE the root startup
/// coordinator has run the first stored-Mac restore for the current scope.
/// In that window auth bootstrap and paired-Mac hydration may still be in
/// flight and the published computer list can be empty while the SQLite
/// store already holds pairings.
///
/// An automatic recovery entering that window used to start an independent
/// dial against that half-initialized state. Its predictable failure armed
/// the account-scoped transient cooldown, and the cooldown then filtered
/// Iroh routes out of the REAL startup restore, settling it as `noRoute`
/// within milliseconds. The first visible connection attempt therefore
/// failed and the Mac only connected when a delayed automatic retry fired
/// seconds later with the cooldown expired.
@MainActor
extension ReconnectRouteSelectionTests {
    private func makeStartupReadinessShell(
        failingKinds: Set<CmxAttachTransportKind> = []
    ) async throws -> (
        shell: MobileShellComposite,
        factory: KindRecordingTransportFactory,
        directory: URL
    ) {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac",
            instanceTag: "default",
            displayName: "Test Mac"
        )
        let factory = KindRecordingTransportFactory(
            router: router,
            box: TransportBox(),
            failingKinds: failingKinds
        )
        let (pairedStore, directory) = try makePairedMacStore()
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try iroh()],
            instanceTag: "default",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        let shell = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "startup-readiness-\(UUID().uuidString)"
            )!
        )
        return (shell, factory, directory)
    }

    /// A directory update delivered before the first stored-Mac restore (the
    /// cold-launch shape: the discovery stream emits its initial snapshot
    /// while auth bootstrap is still in flight) is satisfied by the upcoming
    /// startup restore. It must not claim the recovery owner, must not dial,
    /// and must not arm the account cooldown that would poison that restore.
    @Test func automaticRecoveryBeforeFirstStartupRestoreDefersToStartup() async throws {
        let (shell, factory, directory) = try await makeStartupReadinessShell()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!shell.didFinishStoredMacReconnectAttempt)
        shell.recoverMobileConnection(trigger: .directoryChanged)

        #expect(!shell.connectionRecoveryOwner.isActive)
        #expect(shell.automaticReconnectBackoffOwner.transientRetryAt == nil)

        // The startup restore that follows must be the FIRST dial and must
        // connect on that first attempt.
        #expect(await shell.reconnectActiveMacIfAvailable(
            stackUserID: "user-1",
            hydratePairedMacs: true
        ))
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(shell.connectionState == .connected)

        // Once the first restore has resolved, automatic triggers flow again.
        #expect(shell.didFinishStoredMacReconnectAttempt)
        await shell.remoteClient?.disconnect()
    }

    /// Every pre-restore automatic wake-up defers, not just directory pushes:
    /// each of these can fire during launch (path change, presence snapshot,
    /// a backoff timer surviving a team switch) before the root coordinator
    /// starts the first restore.
    @Test(arguments: [
        MobileShellComposite.RecoveryTrigger.networkChange,
        .presencePush,
        .automaticBackoffExpired,
    ])
    func preRestoreAutomaticTriggersDoNotClaimTheRecoveryOwner(
        trigger: MobileShellComposite.RecoveryTrigger
    ) async throws {
        let (shell, factory, directory) = try await makeStartupReadinessShell()
        defer { try? FileManager.default.removeItem(at: directory) }

        shell.recoverMobileConnection(trigger: trigger)

        #expect(!shell.connectionRecoveryOwner.isActive)
        #expect(!shell.isReconnectingStoredMac)
        #expect(factory.attemptedKinds().isEmpty)
    }

    /// An explicit manual retry is user intent and never defers to startup.
    @Test func manualRetryBeforeFirstStartupRestoreStillDials() async throws {
        let (shell, factory, directory) = try await makeStartupReadinessShell()
        defer { try? FileManager.default.removeItem(at: directory) }

        shell.recoverMobileConnection(trigger: .manual)

        #expect(shell.connectionRecoveryOwner.isActive)
        #expect(try await pollUntil { shell.connectionState == .connected })
        #expect(factory.attemptedKinds() == [.iroh])
        await shell.remoteClient?.disconnect()
    }

    /// An attach-style explicit dial that fails must still end the deferral
    /// window: attach launches skip the root stored restore entirely, so no
    /// restore is coming and automatic wake-ups own recovery again. Without
    /// this, a failed attach would leave every automatic trigger deferred
    /// until a manual retry.
    @Test func failedExplicitConnectEndsTheStartupDeferralWindow() async throws {
        let (shell, factory, directory) = try await makeStartupReadinessShell(
            failingKinds: [.iroh]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let ticket = try MobileShellComposite.storedMacTicket(
            name: "Test Mac",
            routes: [try iroh()],
            pairedMacDeviceID: "test-mac"
        )
        _ = try? await shell.connect(ticket: ticket)
        #expect(shell.connectionState != .connected)
        #expect(!shell.didFinishStoredMacReconnectAttempt)

        shell.recoverMobileConnection(trigger: .directoryChanged)

        #expect(shell.connectionRecoveryOwner.isActive)
        #expect(factory.attemptedKinds().first == .iroh)
        shell.connectionRecoveryOwner.cancel()
    }

    /// The exact failure recorded in the 2026-09-22 diagnostic export: a
    /// failed pre-readiness automatic attempt left the transient cooldown
    /// armed, and the startup restore then filtered Iroh out of every
    /// candidate and settled `No route available` in ~20ms while the Mac was
    /// reachable. A launch restore is fresh user-visible intent, like a
    /// manual retry: residual transient pacing must not starve its dial.
    @Test func startupRestoreDialsDespiteResidualTransientCooldown() async throws {
        let (shell, factory, directory) = try await makeStartupReadinessShell()
        defer { try? FileManager.default.removeItem(at: directory) }

        shell.recordTransientAutomaticReconnectBackoff(accountID: "user-1")
        #expect(shell.automaticReconnectBackoffOwner.transientRetryAt != nil)

        #expect(await shell.reconnectActiveMacIfAvailable(
            stackUserID: "user-1",
            hydratePairedMacs: true
        ))
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(shell.connectionState == .connected)
        await shell.remoteClient?.disconnect()
    }
}

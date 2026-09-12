#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// Graduation P4 slice 2: the cmux-lite-proven transport running as a
/// PARALLEL host inside the real Mac app — its own iroh endpoint, its own
/// ALPN (`cmux/peer/1`), its own relay registration with zero-gap
/// credential rotation — while CmuxIrohTransport continues to serve every
/// existing client untouched. Dev-gated: builds only in DEBUG, is OFF by
/// default, and starts only when the debug default opts in. No production
/// surface changes until the E1 compat verdict
/// (manaflow-ai/cmuxterm-hq#317, TRANSPORT-CONTRACT v16 D7).
///
/// Startup is cache-first and register-when-ready: the endpoint binds
/// IMMEDIATELY (with still-valid Keychain-cached relay credentials when
/// present, direct-only otherwise), the accept loop starts, and the broker
/// mint runs OFF the critical path in a background task that attaches the
/// relay make-before-break. Readiness ratchets
/// `.starting → .bound → .relayAttached → .published`; the presence route
/// and the pairing ticket exist only at `.published`
/// (`NextTransportReadiness`, cmux#9724).
@MainActor
@Observable
final class MobileHostNextTransportRuntime {
    /// Shared logger for the runtime and its bridge companion. Keeping it on
    /// the owning type avoids ambient module-global state while the
    /// nonisolated declaration remains safe to use from worker tasks.
    nonisolated static let logger = Logger(
        subsystem: "dev.cmux",
        category: "mobile-host-next-transport"
    )

    /// Elapsed whole milliseconds used by host and bridge diagnostics.
    nonisolated static func elapsedMs(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int64(elapsed.components.seconds) * 1_000
            + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Scheduler for genuine connection deadlines and credential refresh
    /// delays. It is injected so tests can advance a virtual clock and so no
    /// runtime path relies on an unowned global sleeper.
    let sleep: @Sendable (Duration) async throws -> Void
    let relayCachePolicy = NextTransportRelayCredentialCachePolicy()
    let mintRetryPolicy = NextTransportMintRetryPolicy()

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.sleep = sleep
    }

    /// Debug toggle (mirrors CmxIrohTransportVerificationMode's pattern).
    nonisolated static let debugDefaultsKey = "dev.cmux.nextTransport.enabled"

    /// Keychain service holding the host identity and grant-signer private
    /// keys (generic-password items, one account per key).
    nonisolated static let keyStoreService = "dev.cmux.nextTransport.keys"
    nonisolated static let identityKeyAccount = "host-identity"
    nonisolated static let signerKeyAccount = "grant-signer"
    /// Keychain service holding the last-good relay credential cache.
    nonisolated static let credentialCacheService = "dev.cmux.nextTransport.relayCredentials"
    nonisolated static let credentialCacheAccount = "last-good"
    /// Grants are intentionally finite-lived even though the signer persists;
    /// a stale phone must eventually re-pair rather than retain permanent
    /// access to the bridged application surface.
    nonisolated static let grantLifetimeSeconds: Int64 = 86_400
    private nonisolated static let grantExpiryCheckIntervalSeconds: Int64 = 60
    nonisolated static let grantExpiryGraceSeconds: Int64 = 3_600

    /// Legacy UserDefaults keys (pre-Keychain). Private keys migrate out of
    /// these exactly once (read old → write Keychain → delete old); the
    /// deviceID is not secret and stays in defaults.
    nonisolated static let legacyIdentityKeyDefaultsKey = "dev.cmux.nextTransport.identity.key"
    nonisolated static let legacySignerKeyDefaultsKey = "dev.cmux.nextTransport.signer.key"
    nonisolated static let identityDeviceIDDefaultsKey = "dev.cmux.nextTransport.identity.deviceID"

    /// Dev diagnostic string for the Debug menu, derived from readiness.
    var state: String {
        get { endpointCloseFailed ? "shutdown-failed" : runtimeState }
        set { runtimeState = newValue }
    }
    private var runtimeState = "off"
    private var endpointCloseFailed = false
    /// Startup gate, observable so the Debug menu renders it live. Only
    /// meaningful while the host runs; reset to `.starting` on stop.
    var readiness: NextTransportReadiness = .starting
    var endpointID: String?
    var relayURL: String?
    /// Confirmed admissions only (incremented after `host.activeSession`
    /// proves the serve admitted the connection).
    var admissions = 0

    var endpoint: Endpoint?
    var host: TransportHost?
    var signer: GrantSigner?
    private var startTask: Task<Void, Never>?
    var endpointCloseTask: Task<Bool, Never>?
    var endpointCloseOperation: (@MainActor @Sendable () async -> Bool)?
    var acceptTask: Task<Void, Never>?
    var credentialTask: Task<Void, Never>?
    var serveTasks: [UInt64: Task<Void, Never>] = [:]
    var serveTaskCounter: UInt64 = 0
    var credentialClient: BrokerCredentialClient?
    let grantRevocationStore = MobileHostNextTransportGrantRevocationStore()
    var grantRevocationTask: Task<Void, Never>?
    var endpointOnlineWait: IrohEndpointOnlineWait?
    var issuedGrantIDs: Set<String> = []
    private var grantExpiryTask: Task<Void, Never>?
    /// Withdraws a cached relay route when no broker client exists to renew it.
    var cachedCredentialExpiryTask: Task<Void, Never>?
    /// Single owner for enable/disable races: every start belongs to one
    /// generation, disable bumps it, and every post-await step re-checks it,
    /// so a stale start can never publish (or clobber a newer one).
    var generation: UInt64 = 0
    /// Auth lifecycle observer; a sign-out or account switch immediately
    /// tears down the parallel endpoint so an old account's grants cannot
    /// continue reaching the application lanes.
    private var authObservationTask: Task<Void, Never>?
    private var observedAccountID: String?

    /// OFF by default, even in dev builds: the defaults key must opt in.
    /// The Debug > Next Transport toggle is the control surface.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.debugDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        MobileHostNextTransportRuntime.logger.notice(
            "host runtime setEnabled=\(enabled, privacy: .public) (was \(self.isEnabled, privacy: .public))")
        UserDefaults.standard.set(enabled, forKey: Self.debugDefaultsKey)
        if enabled {
            startIfEnabled()
        } else {
            beginStop(reason: "setEnabled(false)")
        }
    }

    /// Binds the runtime to the app's authenticated-session lifecycle. The
    /// observer is deliberately owned here (rather than a static hook), so
    /// every start/stop path shares one account fence.
    func configure(auth: AuthCoordinator) {
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, let self else { return }
            let identities = auth.authenticatedSessionIdentities()
            for await identity in identities {
                guard !Task.isCancelled else { return }
                let accountID = identity?.accountID
                let previous = self.observedAccountID
                self.observedAccountID = accountID
                if previous != nil, previous != accountID {
                    self.beginStop(reason: "authenticated account changed")
                } else if accountID == nil, self.endpoint != nil || self.startTask != nil {
                    self.beginStop(reason: "authenticated session ended")
                }
                if accountID != nil, self.isEnabled, self.endpoint == nil,
                    self.startTask == nil
                {
                    self.startIfEnabled()
                }
            }
        }
    }

    /// Idempotent: a host that is already starting or running is left alone.
    func startIfEnabled() {
        guard isEnabled else {
            MobileHostNextTransportRuntime.logger.notice("host runtime startIfEnabled: disabled; not starting")
            return
        }
        guard MobileRemoteControlPolicy.isEnabled else {
            MobileHostNextTransportRuntime.logger.notice(
                "host runtime startIfEnabled: managed remote-control disable; not starting")
            return
        }
        guard startTask == nil, endpoint == nil else {
            MobileHostNextTransportRuntime.logger.notice(
                """
                host runtime startIfEnabled: already \
                \(self.endpoint == nil ? "starting" : "running", privacy: .public) \
                state=\(self.state, privacy: .public); not starting again
                """)
            return
        }
        generation &+= 1
        let gen = generation
        startTask = Task { [weak self] in
            await self?.start(generation: gen)
            guard let self, self.generation == gen else { return }
            self.startTask = nil
        }
    }

    /// Stops the independent host when the owning mobile-host service itself
    /// is stopped (app termination or an explicit host shutdown), while
    /// preserving the DEBUG opt-in for the next service start.
    func stopForService() {
        beginStop(reason: "mobile host service stopped")
    }

    /// Withdraws the route synchronously and owns the endpoint's background
    /// close. A new generation waits for this close before binding again.
    private func beginStop(reason: String) {
        MobileHostNextTransportRuntime.logger.notice(
            """
            host stop begin reason=\(reason, privacy: .public) \
            state=\(self.state, privacy: .public) \
            readiness=\(self.readiness.description, privacy: .public) \
            endpoint=\(String(self.endpointID?.prefix(8) ?? "none"), privacy: .public)
            """)
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        acceptTask?.cancel()
        acceptTask = nil
        credentialTask?.cancel()
        credentialTask = nil
        grantExpiryTask?.cancel()
        grantExpiryTask = nil
        cachedCredentialExpiryTask?.cancel()
        cachedCredentialExpiryTask = nil
        endpointOnlineWait?.cancel()
        endpointOnlineWait = nil
        for task in serveTasks.values { task.cancel() }
        serveTasks.removeAll()
        let grantsToRevoke = issuedGrantIDs
        issuedGrantIDs.removeAll()
        if !grantsToRevoke.isEmpty {
            let store = grantRevocationStore
            let previous = grantRevocationTask
            grantRevocationTask = Task {
                await previous?.value
                do { try await store.revoke(grantsToRevoke) }
                catch {
                    Self.logger.error("grant revocation persistence failed; restart remains blocked: \(String(describing: error), privacy: .public)")
                }
            }
        }
        MobileHostService.shared.updateNextTransportRoute(nil)
        MobileHostNextTransportRuntime.logger.notice("presence route CLEARED")
        let closing = endpoint
        endpoint = nil
        host = nil
        signer = nil
        credentialClient = nil
        endpointID = nil
        relayURL = nil
        readiness = .starting
        state = "off"
        if let closing {
            // Closing also unblocks the accept loop and any hello reads the
            // cancelled tasks are still parked on (uniffi futures do not
            // observe Swift task cancellation).
            beginEndpointClose {
                do {
                    try await closing.close()
                    Self.logger.notice("host endpoint closed")
                    return true
                } catch {
                    Self.logger.error("host endpoint close failed; next generation blocked")
                    return false
                }
            }
        }
        MobileHostNextTransportRuntime.logger.notice("host stop done state=off")
    }

    /// Owns the asynchronous close operation independently of a startup caller.
    func beginEndpointClose(_ operation: @escaping @MainActor @Sendable () async -> Bool) {
        let previousClose = endpointCloseTask
        let previousOperation = endpointCloseOperation
        // Normally there is only one endpoint: startup drains this barrier
        // before binding. Retain both operations if teardown is ever chained.
        var previousCleared = previousClose == nil
        let close: @MainActor @Sendable () async -> Bool = {
            if !previousCleared {
                previousCleared = await previousClose?.value != false
                if !previousCleared, let previousOperation {
                    previousCleared = await previousOperation()
                }
                guard previousCleared else { return false }
            }
            return await operation()
        }
        endpointCloseOperation = close
        endpointCloseTask = endpointCloseAttempt(close)
    }

    /// Failure stays observable even across another stop. Only a confirmed
    /// close clears it; cancellation of a start does not cancel resource cleanup.
    func endpointCloseAttempt(
        _ operation: @escaping @MainActor @Sendable () async -> Bool
    ) -> Task<Bool, Never> {
        Task { [weak self] in
            let succeeded = await operation()
            self?.endpointCloseFailed = !succeeded
            return succeeded
        }
    }

    /// Drives the host's grant lifecycle while the endpoint is live. Admission
    /// checks alone cannot retire a connection that remains established past
    /// its grant expiry, so this bounded tick calls the authoritative host
    /// reconciler and reaps transport-closed sessions.
    func startGrantExpiryLoop(host: TransportHost, generation gen: UInt64) {
        grantExpiryTask?.cancel()
        let sleep = self.sleep
        grantExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == gen, self.endpoint != nil else { return }
                await host.enforceExpiries(now: Int64(Date().timeIntervalSince1970))
                _ = await host.reapClosedSessions()
                do {
                    try await sleep(.seconds(Self.grantExpiryCheckIntervalSeconds))
                } catch {
                    return
                }
            }
        }
    }

}
#endif

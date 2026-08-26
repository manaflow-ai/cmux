import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CryptoKit
import Foundation
import Observation
import OSLog

let mobileHostIrohLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-iroh"
)

/// Stages binding state synchronously while secure persistence drains on a
/// lifecycle-cancellable, latest-value serial lane. Live route publication is
/// owned separately by `MobileHostIrohRuntime` after endpoint activation.
@MainActor
final class MobileHostIrohPersistenceQueue {
    typealias Operation = @MainActor @Sendable () async -> Void

    private var pending: Operation?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func publishAndEnqueue(
        publish: @MainActor () -> Void,
        persist: @escaping Operation
    ) {
        publish()
        pending = persist
        guard worker == nil else { return }
        startWorker(generation: generation)
    }

    func cancel() {
        generation &+= 1
        pending = nil
        worker?.cancel()
        worker = nil
    }

    private func startWorker(generation: UInt64) {
        worker = Task { @MainActor [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation expectedGeneration: UInt64) async {
        while generation == expectedGeneration,
              !Task.isCancelled,
              let operation = pending {
            pending = nil
            await operation()
        }
        guard generation == expectedGeneration else { return }
        worker = nil
        if pending != nil, !Task.isCancelled {
            startWorker(generation: expectedGeneration)
        }
    }
}

/// macOS composition root for the account-scoped Iroh host runtime.
@MainActor
final class MobileHostIrohRuntime {
    enum RoutePublicationPhase: Equatable {
        case unavailable
        case starting(revision: UInt64)
        case active(revision: UInt64, binding: CmxIrohBrokerBindingMetadata)
    }

    enum SettingsError: Error, Equatable {
        case unavailable
        case incompleteCustomRelay
        case missingCustomRelay
    }
    static let shared = MobileHostIrohRuntime()

    static let capabilities = [
        "mobile-rpc-v1",
        "multistream-v1",
        MobileHostService.irohPrivatePathsCapability,
    ]
    #if DEBUG
    static let debugRelayOnlyDefaultsKey = "cmux.iroh.debug.relay-only"
    #endif

    let appInstances: CmxIrohAppInstanceRepository
    let identities: CmxIrohIdentityRepository
    let brokerCredentials: CmxIrohBrokerCredentialRepository
    let brokerBackpressureGate: CmxIrohBrokerBackpressureGate
    let hostPolicies: CmxIrohHostPolicyCache
    let pendingRevocations: CmxIrohPendingRevocationOutbox
    let customRelayProfiles: CmxIrohCustomRelayProfileStore
    let relayPolicyCache: CmxIrohRelayPolicyCache
    let relayPreferenceStore: CmxIrohRelayPreferenceStore
    let customRelayCredentials: CmxIrohCustomRelayCredentialStore
    let relayPolicyTrustRoot: CmxIrohRelayPolicyTrustRoot?
    let lanPublisher: CmxIrohLANHostPublisher
    /// Release-safe, bounded host-side connection timeline. Event payloads are
    /// fixed numeric categories, never peer identities, addresses, or tokens.
    let diagnosticLog: DiagnosticLog
    let authObserver = MobileHostIrohAuthObserver()
    let bindingPersistenceQueue = MobileHostIrohPersistenceQueue()

    weak var auth: AuthCoordinator?
    var authObservationTask: Task<Void, Never>?
    var transitionTask: Task<Void, Never>?
    var runtime: CmxIrohHostRuntime?
    var relayPolicyService: CmxIrohRelayPolicyService?
    /// The policy most recently accepted by the live endpoint. The policy
    /// service may resolve a newer value before the endpoint installs it, so
    /// lifecycle expiry decisions must retain this applied snapshot separately
    /// from `relayPolicyEffective` (the service's latest resolved value).
    var relayPolicyAppliedEffective: CmxIrohEffectiveRelayPolicy?
    var relayPolicyEffective: CmxIrohEffectiveRelayPolicy?
    var relayPolicyDiagnostics: CmxIrohRelayDiagnosticsSnapshot?
    var relayPolicyEndpointID: CmxIrohPeerIdentity?
    var relayPolicyObservationTask: Task<Void, Never>?
    var relayPolicyRefreshTask: Task<Void, Never>?
    var relayPolicyRefreshTaskID: UUID?
    var relayPolicyRefreshService: CmxIrohRelayPolicyService?
    var relayPolicyRefreshAccountID: String?
    var relayPolicyRefreshEndpointID: CmxIrohPeerIdentity?
    var relayPolicyRefreshTrustRoot: CmxIrohRelayPolicyTrustRoot?
    var relayPolicyRefreshRevision: UInt64?
    /// Last platform path state. `nil` means the path observer has not emitted
    /// its first sample yet; an initial activation may proceed, while relay
    /// policy probes remain parked until an authoritative usable-path sample.
    var relayPolicyNetworkReachable: Bool?
    var relayPolicyRefreshClock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    var selectedPathObservationTask: Task<Void, Never>?
    var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    var desiredActive = false
    var observedAccountID: String?
    var activeAccountID: String?
    var activeAppInstanceID: String?
    var lastKnownAccountID: String?
    var lastKnownTag: String?
    var lastKnownBindingID: String?
    var pendingIrohRouteBinding: (
        revision: UInt64,
        binding: CmxIrohBrokerBindingMetadata,
        pathHints: [CmxIrohPathHint]
    )?
    var routePublicationPhase: RoutePublicationPhase = .unavailable
    var preparedSignOut: CmxIrohHostSignOutPreparation?
    var signOutIntentActive = false
    var signOutPreparationTask: Task<Void, Never>?
    var signOutPreparationRevision: UInt64 = 0
    var lifecycleRevision: UInt64 = 0
    var nextDiagnosticSessionID = 0
    var failureRecoveryTask: Task<Void, Never>?
    var retryInspectionTask: Task<Void, Never>?
    var retryInspectionRevision: UInt64 = 0
    var failureRecoveryFailureCount = 0
    var failureRecoveryClock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    /// Terminal endpoint recovery remains on the short host-runtime ladder.
    /// Relay-policy refreshes select their longer broker-specific schedule in
    /// `scheduleRelayPolicyRefresh`; keeping this profile separate prevents a
    /// broker outage from stranding endpoint activation for hours.
    var failureRecoverySchedule = CmxIrohRetrySchedule()
    var failureRecoveryJitter: @Sendable () -> Double = {
        Double.random(in: 0 ... 1)
    }
    var relayPolicyRetryJitter: @Sendable () -> Double = {
        Double.random(in: 0 ... 1)
    }
    /// Single-flight owner for revision reconciliation: one task in flight,
    /// later signals coalesce at the greatest observed revision.
    var serverSignalRefreshTask: Task<Void, Never>?
    var serverSignalRefreshTaskID: UUID?
    var serverSignalRefreshRevision: UInt64?
    var serverSignalPendingRevision: UInt64?

    private init() {
        let installState = CmxIrohUserDefaultsInstallStateStore()
        diagnosticLog = Self.hostDiagnosticLog
        appInstances = CmxIrohAppInstanceRepository(store: installState)
        brokerBackpressureGate = CmxIrohBrokerBackpressureGate(store: installState)
        #if DEBUG
        identities = CmxIrohIdentityRepository(
            secureStore: CmxIrohDevelopmentFileIdentityStore(
                directory: Self.developmentStoreDirectory(service: "identity")
            ),
            installState: installState
        )
        brokerCredentials = CmxIrohBrokerCredentialRepository(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(
                    service: "broker-credentials"
                )
            ),
            installState: installState
        )
        hostPolicies = CmxIrohHostPolicyCache(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "host-policy")
            )
        )
        pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(
                    service: "pending-revocations"
                )
            )
        )
        customRelayProfiles = CmxIrohCustomRelayProfileStore(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "custom-relays")
            )
        )
        relayPolicyCache = CmxIrohRelayPolicyCache(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "relay-policy")
            )
        )
        relayPreferenceStore = CmxIrohRelayPreferenceStore(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "relay-preference")
            )
        )
        customRelayCredentials = CmxIrohCustomRelayCredentialStore(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "custom-relay-credentials")
            )
        )
        #else
        identities = CmxIrohIdentityRepository(installState: installState)
        brokerCredentials = CmxIrohBrokerCredentialRepository(
            installState: installState
        )
        hostPolicies = CmxIrohHostPolicyCache()
        pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: CmxIrohKeychainCredentialStore(
                service: "com.cmuxterm.iroh.pending-revocations.v1"
            )
        )
        customRelayProfiles = CmxIrohCustomRelayProfileStore()
        relayPolicyCache = CmxIrohRelayPolicyCache()
        relayPreferenceStore = CmxIrohRelayPreferenceStore()
        customRelayCredentials = CmxIrohCustomRelayCredentialStore()
        #endif
        relayPolicyTrustRoot = Self.relayPolicyTrustRoot(
            infoDictionary: Bundle.main.infoDictionary
        )
        lanPublisher = CmxIrohLANHostPublisher()
    }

    /// The host diagnostic ring, deliberately `nonisolated` so read paths like
    /// the `iroh_diag` socket verb can snapshot it without a main-actor hop:
    /// the ring must stay exportable even when the main thread is wedged,
    /// which is exactly when connection diagnostics matter most.
    nonisolated static let hostDiagnosticLog = DiagnosticLog(
        buildStamp: MobileHostIrohRuntime.diagnosticBuildStamp,
        role: .macHost
    )

    private nonisolated static var diagnosticBuildStamp: String {
        DiagnosticBuildStamp.make(infoDictionary: Bundle.main.infoDictionary)
    }

    @discardableResult
    func scheduleReconcile(
        eraseAccountState: Bool,
        restartActiveRuntime: Bool = false
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
        cancelRetryInspection()
        bindingPersistenceQueue.cancel()
        serverSignalRefreshTask?.cancel()
        serverSignalRefreshTask = nil
        serverSignalRefreshTaskID = nil
        serverSignalRefreshRevision = nil
        serverSignalPendingRevision = nil
        let revision = lifecycleRevision
        let previous = transitionTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, revision == self.lifecycleRevision else { return }
            await self.reconcile(
                targetAccountID: self.signOutIntentActive
                    ? nil
                    : (self.desiredActive ? self.observedAccountID : nil),
                eraseAccountState: eraseAccountState || self.signOutIntentActive,
                restartActiveRuntime: restartActiveRuntime,
                revision: revision
            )
            if revision == self.lifecycleRevision {
                self.transitionTask = nil
            }
        }
        transitionTask = task
        return task
    }

    func reconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        restartActiveRuntime: Bool,
        revision: UInt64
    ) async {
        // Each transition re-derives failure recovery from its own outcome:
        // success resets the backoff ladder, failure re-arms it, and a
        // deactivating transition ends the need for it.
        cancelFailureRecovery(resetBackoff: false)
        if eraseAccountState {
            clearIrohRoutePublication(revision: revision)
            await quarantineForSignOut()
        } else if restartActiveRuntime
                    || activeAccountID != targetAccountID
                    || targetAccountID == nil {
            let previousRuntime = runtime
            runtime = nil
            clearIrohRoutePublication(revision: revision)
            selectedPathObservationTask?.cancel()
            selectedPathObservationTask = nil
            activeAccountID = nil
            activeAppInstanceID = nil
            await previousRuntime?.stop()
            if previousRuntime != nil {
                diagnosticLog.record(DiagnosticEvent(
                    .endpointStopped,
                    a: DiagnosticTransportKind.iroh.rawValue
                ))
            }
            await lanPublisher.stop()
            clearRelayPolicyRuntimeState()
        }

        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              Self.shouldStartIrohActivation(networkReachable: relayPolicyNetworkReachable),
              let targetAccountID,
              runtime == nil else { return }

        diagnosticLog.record(DiagnosticEvent(
            .endpointStarting,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        do {
            try await activate(accountID: targetAccountID, revision: revision)
            failureRecoveryFailureCount = 0
        } catch is CancellationError {
            return
        } catch {
            let failureKind = Self.diagnosticFailureKind(for: error)
            let failureType = String(reflecting: type(of: error))
            diagnosticLog.record(DiagnosticEvent(
                .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: failureKind.rawValue
            ))
            mobileHostIrohLog.error(
                "Iroh host activation failed kind=\(failureKind.rawValue, privacy: .public) type=\(failureType, privacy: .public) detail=\(String(describing: error), privacy: .private)"
            )
            guard !Self.shouldPauseRelayPolicyRetry(
                failure: failureKind,
                networkReachable: relayPolicyNetworkReachable
            ) else { return }
            scheduleFailureRecovery()
        }
    }

    /// Returns whether a host activation may begin with the current path state.
    /// An unknown initial path may use cached policy for direct startup, while
    /// an explicitly offline path waits for the reachability owner to wake it.
    nonisolated static func shouldStartIrohActivation(networkReachable: Bool?) -> Bool {
        networkReachable != false
    }

    /// Returns whether an externally delivered connectivity signal must be
    /// retained until the path monitor reports a usable route.
    nonisolated static func shouldDeferServerConnectivitySignal(networkReachable: Bool?) -> Bool {
        networkReachable != true
    }

    nonisolated static func diagnosticFailureKind(
        for error: any Error
    ) -> DiagnosticFailureKind {
        DiagnosticFailureKind.classify(error)
    }

    /// An account-scoped invalidation says a newer authoritative route
    /// revision exists. One owned task performs a read-only v2 reconciliation;
    /// bursts coalesce at the greatest revision instead of creating one waiter
    /// per frame. Terminal evidence rebuilds through the shared lifecycle path.
    func reconcileConnectivityFromServerSignal(revision: UInt64) {
        guard !Self.shouldDeferServerConnectivitySignal(
            networkReachable: relayPolicyNetworkReachable
        ) else {
            serverSignalPendingRevision = max(
                serverSignalPendingRevision ?? revision,
                revision
            )
            return
        }
        if serverSignalRefreshTask != nil {
            serverSignalPendingRevision = max(
                serverSignalPendingRevision ?? revision,
                revision
            )
            return
        }
        guard let signalRuntime = runtime else {
            retryIfNeeded()
            return
        }
        let taskID = UUID()
        serverSignalRefreshTaskID = taskID
        serverSignalRefreshRevision = revision
        serverSignalRefreshTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   self.serverSignalRefreshTaskID == taskID {
                    self.serverSignalRefreshTask = nil
                    self.serverSignalRefreshTaskID = nil
                    self.serverSignalRefreshRevision = nil
                }
            }
            guard let self,
                  self.serverSignalRefreshTaskID == taskID,
                  !Task.isCancelled,
                  self.relayPolicyNetworkReachable == true else {
                if let self,
                   self.serverSignalRefreshTaskID == taskID,
                   self.relayPolicyNetworkReachable != true {
                    self.serverSignalPendingRevision = max(
                        self.serverSignalPendingRevision ?? revision,
                        revision
                    )
                }
                return
            }
            _ = await signalRuntime.reconcileConnectivityRevision(revision)
            guard self.serverSignalRefreshTaskID == taskID else { return }
            let replayRevision = self.serverSignalPendingRevision
            self.serverSignalPendingRevision = nil
            guard !Task.isCancelled,
                  self.relayPolicyNetworkReachable == true else {
                self.serverSignalPendingRevision = max(
                    replayRevision ?? revision,
                    revision
                )
                return
            }
            guard self.runtime === signalRuntime,
                  self.desiredActive,
                  !self.signOutIntentActive,
                  self.transitionTask == nil,
                  self.relayPolicyNetworkReachable == true else {
                if self.relayPolicyNetworkReachable != true {
                    self.serverSignalPendingRevision = max(
                        replayRevision ?? revision,
                        revision
                    )
                }
                return
            }
            // Release this single-flight slot before replaying a coalesced
            // revision; otherwise the recursive call would only requeue it.
            self.serverSignalRefreshTask = nil
            self.serverSignalRefreshTaskID = nil
            self.serverSignalRefreshRevision = nil
            if await signalRuntime.snapshot().state == .failed {
                guard self.runtime === signalRuntime,
                      self.desiredActive,
                      !self.signOutIntentActive,
                      self.transitionTask == nil,
                      self.relayPolicyNetworkReachable == true else { return }
                self.scheduleReconcile(
                    eraseAccountState: false,
                    restartActiveRuntime: true
                )
                return
            }
            if let replayRevision {
                self.reconcileConnectivityFromServerSignal(
                    revision: replayRevision
                )
            }
        }
    }

    func makeDiagnosticSessionID() -> Int {
        if nextDiagnosticSessionID == Int.max {
            nextDiagnosticSessionID = 1
        } else {
            nextDiagnosticSessionID += 1
        }
        return nextDiagnosticSessionID
    }
}

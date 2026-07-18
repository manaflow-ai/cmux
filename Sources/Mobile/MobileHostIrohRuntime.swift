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

/// Publishes live binding state synchronously while secure persistence drains
/// on a lifecycle-cancellable, latest-value serial lane.
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
    enum SettingsError: Error, Equatable {
        case unavailable
        case incompleteCustomRelay
        case missingCustomRelay
    }
    static let shared = MobileHostIrohRuntime()

    static let capabilities = ["mobile-rpc-v1", "multistream-v1"]
    #if DEBUG
    static let debugRelayOnlyDefaultsKey = "cmux.iroh.debug.relay-only"
    #endif

    let appInstances: CmxIrohAppInstanceRepository
    let identities: CmxIrohIdentityRepository
    let brokerCredentials: CmxIrohBrokerCredentialRepository
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
    var relayPolicyEffective: CmxIrohEffectiveRelayPolicy?
    var relayPolicyDiagnostics: CmxIrohRelayDiagnosticsSnapshot?
    var relayPolicyEndpointID: CmxIrohPeerIdentity?
    var relayPolicyObservationTask: Task<Void, Never>?
    var relayPolicyRefreshTask: Task<Void, Never>?
    var selectedPathObservationTask: Task<Void, Never>?
    var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    var desiredActive = false
    var observedAccountID: String?
    var activeAccountID: String?
    var activeAppInstanceID: String?
    var lastKnownAccountID: String?
    var lastKnownTag: String?
    var lastKnownBindingID: String?
    var preparedSignOut: CmxIrohHostSignOutPreparation?
    var signOutIntentActive = false
    var signOutPreparationTask: Task<Void, Never>?
    var signOutPreparationRevision: UInt64 = 0
    var lifecycleRevision: UInt64 = 0

    private init() {
        diagnosticLog = DiagnosticLog(
            buildStamp: Self.diagnosticBuildStamp,
            role: .macHost
        )
        appInstances = CmxIrohAppInstanceRepository()
        #if DEBUG
        identities = CmxIrohIdentityRepository(
            secureStore: CmxIrohDevelopmentFileIdentityStore(
                directory: Self.developmentStoreDirectory(service: "identity")
            )
        )
        brokerCredentials = CmxIrohBrokerCredentialRepository(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(
                    service: "broker-credentials"
                )
            )
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
        identities = CmxIrohIdentityRepository()
        brokerCredentials = CmxIrohBrokerCredentialRepository()
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

    private static var diagnosticBuildStamp: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleName"] as? String ?? "cmux"
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(name) \(version) (\(build))"
    }

    @discardableResult
    func scheduleReconcile(
        eraseAccountState: Bool,
        restartActiveRuntime: Bool = false
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
        bindingPersistenceQueue.cancel()
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
        if eraseAccountState {
            await quarantineForSignOut()
        } else if restartActiveRuntime
                    || activeAccountID != targetAccountID
                    || targetAccountID == nil {
            let previousRuntime = runtime
            runtime = nil
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
              let targetAccountID,
              runtime == nil else { return }

        diagnosticLog.record(DiagnosticEvent(
            .endpointStarting,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        do {
            try await activate(accountID: targetAccountID, revision: revision)
        } catch is CancellationError {
            return
        } catch {
            diagnosticLog.record(DiagnosticEvent(
                .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: Self.diagnosticFailureKind(for: error).rawValue
            ))
            mobileHostIrohLog.error(
                "Iroh host activation failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    nonisolated static func diagnosticFailureKind(
        for error: any Error
    ) -> DiagnosticFailureKind {
        DiagnosticFailureKind.classify(error)
    }
}

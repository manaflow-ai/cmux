import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CryptoKit
import Foundation
import Observation
import OSLog

private let mobileHostIrohLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-iroh"
)

private struct MobileHostIrohAuthState: Equatable, Sendable {
    let accountID: String?
}

@MainActor
private final class MobileHostIrohAuthObserver {
    private weak var auth: AuthCoordinator?
    private var continuation: AsyncStream<MobileHostIrohAuthState>.Continuation?

    func states(for auth: AuthCoordinator) -> AsyncStream<MobileHostIrohAuthState> {
        stop()
        self.auth = auth
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            observe()
        }
    }

    func stop() {
        let previous = continuation
        continuation = nil
        auth = nil
        previous?.finish()
    }

    private func observe() {
        guard let auth, let continuation else { return }
        let state = withObservationTracking {
            MobileHostIrohAuthState(
                accountID: auth.isAuthenticated ? auth.currentUser?.id : nil
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        continuation.yield(state)
    }
}

/// macOS composition root for the account-scoped Iroh host runtime.
@MainActor
final class MobileHostIrohRuntime {
    static let shared = MobileHostIrohRuntime()

    private static let managedRelayURLs: Set<String> = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]
    private static let capabilities = ["mobile-rpc-v1", "multistream-v1"]

    private let appInstances: CmxIrohAppInstanceRepository
    private let identities: CmxIrohIdentityRepository
    private let brokerCredentials: CmxIrohBrokerCredentialRepository
    private let hostPolicies: CmxIrohHostPolicyCache
    private let pendingRevocations: CmxIrohPendingRevocationOutbox
    private let lanPublisher: CmxIrohLANHostPublisher
    private let authObserver = MobileHostIrohAuthObserver()

    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var runtime: CmxIrohHostRuntime?
    private var desiredActive = false
    private var observedAccountID: String?
    private var activeAccountID: String?
    private var activeAppInstanceID: String?
    private var lastKnownAccountID: String?
    private var lastKnownTag: String?
    private var lastKnownBindingID: String?
    private var preparedSignOut: CmxIrohHostSignOutPreparation?
    private var signOutIntentActive = false
    private var signOutPreparationTask: Task<Void, Never>?
    private var lifecycleRevision: UInt64 = 0

    private init() {
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
        #else
        identities = CmxIrohIdentityRepository()
        brokerCredentials = CmxIrohBrokerCredentialRepository()
        hostPolicies = CmxIrohHostPolicyCache()
        pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: CmxIrohKeychainCredentialStore(
                service: "com.cmuxterm.iroh.pending-revocations.v1"
            )
        )
        #endif
        lanPublisher = CmxIrohLANHostPublisher()
    }

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, let self else { return }
            let states = self.authObserver.states(for: auth)
            for await state in states {
                guard !Task.isCancelled else { return }
                let previousAccountID = self.observedAccountID
                self.observedAccountID = state.accountID
                if self.signOutIntentActive {
                    if state.accountID == nil {
                        self.signOutIntentActive = false
                        self.signOutPreparationTask = nil
                    }
                    continue
                }
                guard state.accountID != nil
                        || previousAccountID != nil
                        || self.activeAccountID != nil
                        || self.runtime != nil else { continue }
                self.scheduleReconcile(
                    eraseAccountState: (state.accountID == nil
                        && (previousAccountID != nil
                            || self.activeAccountID != nil
                            || self.runtime != nil))
                        || (previousAccountID != nil
                            && previousAccountID != state.accountID)
                        || (self.activeAccountID != nil
                            && self.activeAccountID != state.accountID)
                        || self.preparedSignOut?.wasPersisted == false
                )
            }
        }
    }

    func setDesiredActive(_ desired: Bool) {
        guard desiredActive != desired else {
            if desired { retryIfNeeded() }
            return
        }
        desiredActive = desired
        guard !signOutIntentActive else { return }
        scheduleReconcile(eraseAccountState: false)
    }

    func retryIfNeeded() {
        guard !signOutIntentActive,
              desiredActive,
              observedAccountID != nil else { return }
        if preparedSignOut?.wasPersisted == false {
            scheduleReconcile(eraseAccountState: true)
            return
        }
        if runtime != nil {
            let revision = lifecycleRevision
            Task { @MainActor [weak self] in
                guard let self,
                      self.desiredActive,
                      self.runtime != nil,
                      revision == self.lifecycleRevision else { return }
                await self.lanPublisher.permissionMayHaveChanged()
            }
            return
        }
        scheduleReconcile(eraseAccountState: false)
    }

    /// Stops the endpoint and durably quarantines its binding before auth clears tokens.
    func prepareSignOut() async {
        if let signOutPreparationTask {
            await signOutPreparationTask.value
            return
        }
        signOutIntentActive = true
        let task = scheduleReconcile(eraseAccountState: true)
        signOutPreparationTask = task
        await task.value
    }

    /// Uses auth's captured tokens to revoke the exact preparation made before clear.
    func revokeAfterSignOut(
        accessToken: String?,
        refreshToken: String?
    ) async {
        observedAccountID = nil
        if let signOutPreparationTask {
            await signOutPreparationTask.value
        } else if preparedSignOut == nil {
            await prepareSignOut()
        }
        defer {
            signOutIntentActive = false
            signOutPreparationTask = nil
        }

        guard var preparation = preparedSignOut else { return }
        if preparation.pendingRevocation == nil {
            preparedSignOut = nil
            return
        }
        preparation = await retryPersistingQuarantinedPreparation(preparation)

        guard let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else { return }
        do {
            let broker = try CmxIrohTrustBrokerClient(
                baseURL: AuthEnvironment.vmAPIBaseURL,
                tokenSource: CmxIrohBrokerTokenSource(
                    accessToken: { accessToken },
                    refreshToken: { refreshToken }
                )
            )
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
            if !preparation.wasPersisted {
                await wipePersistedAccountState(
                    after: CmxIrohHostSignOutPreparation(
                        pendingRevocation: preparation.pendingRevocation,
                        wasPersisted: true
                    )
                )
            }
            if preparedSignOut?.pendingRevocation == preparation.pendingRevocation {
                preparedSignOut = nil
            }
        } catch {
            mobileHostIrohLog.error(
                "Iroh binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    @discardableResult
    private func scheduleReconcile(
        eraseAccountState: Bool
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
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
                revision: revision
            )
            if revision == self.lifecycleRevision {
                self.transitionTask = nil
            }
        }
        transitionTask = task
        return task
    }

    private func reconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        revision: UInt64
    ) async {
        if eraseAccountState {
            await quarantineForSignOut()
        } else if activeAccountID != targetAccountID || targetAccountID == nil {
            let previousRuntime = runtime
            runtime = nil
            activeAccountID = nil
            activeAppInstanceID = nil
            await previousRuntime?.stop()
            await lanPublisher.stop()
        }

        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              let targetAccountID,
              runtime == nil else { return }

        do {
            try await activate(accountID: targetAccountID, revision: revision)
        } catch is CancellationError {
            return
        } catch {
            mobileHostIrohLog.error(
                "Iroh host activation failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func activate(accountID: String, revision: UInt64) async throws {
        guard let auth else { throw CmxIrohHostRuntimeError.inactive }
        let tag = Self.currentTag()
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let deviceID = MobileHostIdentity.deviceID().lowercased()
        let cachedBinding = try await brokerCredentials.loadBinding(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        guard let derivedEndpointID = identity.peerIdentity else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let bindingMatches = cachedBinding.map {
            $0.deviceID == deviceID
                && $0.appInstanceID == appInstanceID
                && $0.tag == tag
                && $0.platform == .mac
                && derivedEndpointID == $0.endpointID
                && $0.identityGeneration == identity.generation
        } ?? false
        let cachedRelay: CmxIrohRelayTokenResponse?
        if let cachedBinding, bindingMatches {
            lastKnownBindingID = cachedBinding.bindingID
            lastKnownAccountID = accountID
            lastKnownTag = tag
            cachedRelay = try await brokerCredentials.loadRelayCredential(
                accountID: accountID,
                binding: cachedBinding,
                expectedRelayFleet: Self.managedRelayURLs,
                now: Date()
            )
        } else {
            cachedRelay = nil
        }
        let policyExpectation = try CmxIrohHostPolicyExpectation(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            endpointID: derivedEndpointID,
            identityGeneration: identity.generation,
            pairingEnabled: true,
            capabilities: Self.capabilities
        )
        let cachedHostPolicy: CmxIrohCachedHostPolicy?
        do {
            cachedHostPolicy = try await hostPolicies.load(
                for: policyExpectation,
                now: Date()
            )
        } catch {
            cachedHostPolicy = nil
            mobileHostIrohLog.error(
                "Iroh offline policy load failed: \(String(describing: error), privacy: .private)"
            )
        }
        if let cachedHostPolicy {
            lastKnownBindingID = cachedHostPolicy.binding.bindingID
            lastKnownAccountID = accountID
            lastKnownTag = tag
        }

        let broker = try CmxIrohTrustBrokerClient(
            baseURL: AuthEnvironment.vmAPIBaseURL,
            tokenSource: CmxIrohBrokerTokenSource(
                accessToken: { [weak auth] in
                    guard let auth,
                          let tokens = try? await auth.currentTokens() else { return nil }
                    return tokens.accessToken
                },
                refreshToken: { [weak auth] in
                    guard let auth,
                          let tokens = try? await auth.currentTokens() else { return nil }
                    return tokens.refreshToken
                }
            )
        )
        let configuration = CmxIrohHostRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            displayName: MobileHostIdentity.displayName(),
            identity: identity,
            pairingEnabled: true,
            capabilities: Self.capabilities,
            bindPolicy: .preferred(
                try CmxIrohBindAddress(
                    ipAddress: "0.0.0.0",
                    port: UInt16(MobileHostService.configuredPort())
                )
            ),
            managedRelayURLs: Self.managedRelayURLs,
            cachedRelayCredential: cachedRelay,
            cachedHostPolicy: cachedHostPolicy
        )
        let credentialRepository = brokerCredentials
        let hostPolicyCache = hostPolicies
        let lanPublisher = lanPublisher
        let managedRelayURLs = Self.managedRelayURLs
        let hostRuntime = CmxIrohHostRuntime(
            factory: CmxIrohLibEndpointFactory(),
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, isCurrent in
                let eventWriter = MobileHostIrohServerEventWriter(
                    session: session
                )
                await MobileHostService.acceptTransport(
                    session.controlTransport,
                    authorization: .irohAdmission(session.peer),
                    independentEventWriter: eventWriter,
                    isCurrent: isCurrent
                )
            },
            handleBinding: { [weak self] registration, discovery, attestation in
                let binding = registration.binding
                let metadata = CmxIrohBrokerBindingMetadata(binding: binding)
                try? await credentialRepository.saveBinding(
                    metadata,
                    accountID: accountID
                )
                if let attestation,
                   let discovered = discovery.bindings.first(where: {
                       $0.bindingID == binding.bindingID
                   }) {
                    do {
                        let policy = try CmxIrohCachedHostPolicy(
                            binding: discovered,
                            grantVerificationKeys: discovery.grantVerificationKeys,
                            endpointAttestation: attestation,
                            lanRendezvous: discovery.lanRendezvous
                        )
                        try await hostPolicyCache.save(
                            policy,
                            for: policyExpectation,
                            now: Date()
                        )
                    } catch {
                        try? await hostPolicyCache.delete(for: policyExpectation)
                        mobileHostIrohLog.error(
                            "Iroh offline policy cache rejected: \(String(describing: error), privacy: .private)"
                        )
                    }
                } else if cachedHostPolicy?.binding != metadata {
                    try? await hostPolicyCache.delete(for: policyExpectation)
                }
                await MainActor.run {
                    guard let self, revision == self.lifecycleRevision else { return }
                    self.lastKnownBindingID = binding.bindingID
                    self.lastKnownAccountID = accountID
                    self.lastKnownTag = tag
                    if self.preparedSignOut?.pendingRevocation?.accountID == accountID {
                        self.preparedSignOut = nil
                    }
                    MobileHostService.shared.updateIrohBinding(binding)
                }
            },
            handleDeactivation: { bindingID in
                await lanPublisher.stop()
                await MainActor.run {
                    if let bindingID {
                        MobileHostService.shared.closeIrohConnections(
                            bindingID: bindingID
                        )
                    }
                    MobileHostService.shared.updateIrohBinding(nil)
                }
            },
            handleRelayCredential: { response, binding in
                try? await credentialRepository.saveRelayCredential(
                    response,
                    accountID: accountID,
                    binding: binding,
                    expectedRelayFleet: managedRelayURLs,
                    now: Date()
                )
            },
            handleLANRefresh: {
                await lanPublisher.refresh()
            },
            handleLANPolicy: { context, directAddresses in
                await lanPublisher.activate(
                    rendezvous: context.rendezvous,
                    binding: context.binding,
                    directAddresses: directAddresses
                )
            }
        )

        do {
            try await hostRuntime.start()
        } catch {
            if revision != lifecycleRevision || Task.isCancelled {
                runtime = hostRuntime
                activeAccountID = accountID
                activeAppInstanceID = appInstanceID
                throw CancellationError()
            }
            await hostRuntime.stop()
            throw error
        }
        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              observedAccountID == accountID else {
            // The succeeding reconcile owns this runtime. Retaining it lets a
            // sign-out or account-switch transition capture a binding that was
            // registered while activation was being superseded.
            runtime = hostRuntime
            activeAccountID = accountID
            activeAppInstanceID = appInstanceID
            throw CancellationError()
        }
        runtime = hostRuntime
        activeAccountID = accountID
        activeAppInstanceID = appInstanceID
        if preparedSignOut?.pendingRevocation?.accountID == accountID {
            preparedSignOut = nil
        }
    }

    private func quarantineForSignOut() async {
        let preparation: CmxIrohHostSignOutPreparation
        if let runtime {
            preparation = await runtime.deactivateForSignOut()
        } else {
            preparation = await prepareWithoutRuntime()
        }
        preparedSignOut = preparation
        await lanPublisher.stop()
        if preparation.wasPersisted {
            await wipePersistedAccountState(after: preparation)
        } else {
            mobileHostIrohLog.error(
                "Iroh binding quarantine persistence failed; account state retained"
            )
        }
    }

    private func prepareWithoutRuntime() async -> CmxIrohHostSignOutPreparation {
        let pending: CmxIrohPendingRevocation?
        if preparedSignOut?.wasPersisted == false {
            pending = preparedSignOut?.pendingRevocation
        } else {
            pending = currentPendingRevocation()
                ?? preparedSignOut?.pendingRevocation
        }
        var wasPersisted = pending == nil || preparedSignOut?.wasPersisted == true
        if let pending, !wasPersisted {
            do {
                try await pendingRevocations.enqueue(pending)
                wasPersisted = true
            } catch {
                mobileHostIrohLog.error(
                    "Iroh binding quarantine persistence failed: \(String(describing: error), privacy: .private)"
                )
            }
        }
        return CmxIrohHostSignOutPreparation(
            pendingRevocation: pending,
            wasPersisted: wasPersisted
        )
    }

    private func retryPersistingQuarantinedPreparation(
        _ preparation: CmxIrohHostSignOutPreparation
    ) async -> CmxIrohHostSignOutPreparation {
        guard !preparation.wasPersisted else { return preparation }
        let retried: CmxIrohHostSignOutPreparation
        if let runtime {
            retried = await runtime.deactivateForSignOut()
        } else {
            retried = await prepareWithoutRuntime()
        }
        guard retried.pendingRevocation == preparation.pendingRevocation else {
            mobileHostIrohLog.error(
                "Iroh binding quarantine retry returned a different binding"
            )
            return preparation
        }
        preparedSignOut = retried
        if retried.wasPersisted {
            await wipePersistedAccountState(after: retried)
        }
        return retried
    }

    private func wipePersistedAccountState(
        after preparation: CmxIrohHostSignOutPreparation
    ) async {
        guard preparation.wasPersisted else { return }
        do {
            try await hostPolicies.deactivate()
        } catch {
            mobileHostIrohLog.error(
                "Iroh offline policy deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        do {
            try await brokerCredentials.deactivate()
        } catch {
            mobileHostIrohLog.error(
                "Iroh broker credential deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        do {
            try await identities.deactivate()
        } catch {
            mobileHostIrohLog.error(
                "Iroh identity deletion failed: \(String(describing: error), privacy: .private)"
            )
        }
        await appInstances.deactivate()
        runtime = nil
        activeAccountID = nil
        activeAppInstanceID = nil
        lastKnownBindingID = nil
        lastKnownAccountID = nil
        lastKnownTag = nil
    }

    private func currentPendingRevocation() -> CmxIrohPendingRevocation? {
        guard let accountID = lastKnownAccountID ?? activeAccountID,
              let tag = lastKnownTag,
              let bindingID = lastKnownBindingID else { return nil }
        return try? CmxIrohPendingRevocation(
            accountID: accountID,
            tag: tag,
            bindingID: bindingID
        )
    }

    #if DEBUG
    private static func developmentStoreDirectory(service: String) -> URL {
        let rawBundleScope = Bundle.main.bundleIdentifier
            ?? "com.cmuxterm.app.debug"
        let bundleScope = String(rawBundleScope.map { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || ["-", ".", "_"].contains(character))
                ? character
                : "_"
        })
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("iroh-debug", isDirectory: true)
            .appendingPathComponent(bundleScope, isDirectory: true)
            .appendingPathComponent(service, isDirectory: true)
    }
    #endif

    private static func currentTag(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        if let raw = environment["CMUX_TAG"],
           let normalized = safeTag(raw) {
            return normalized
        }
        if bundleIdentifier == "com.cmuxterm.app.nightly" { return "nightly" }
        #if DEBUG
        return "dev"
        #else
        return "stable"
        #endif
    }

    private static func safeTag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = String(trimmed.prefix(64)).lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character
                : "-"
        }
        let value = String(normalized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return value.isEmpty ? nil : value
    }
}

private enum MobileHostIrohServerEventWriterError: Error {
    case closed
    case superseded
    case concurrentSend
    case sendTimedOut
}

/// Owns one reusable `serverEvents` send stream. The host connection supplies
/// the bounded event queue; this writer rejects concurrent sends and bounds
/// QUIC flow-control stalls so the caller can immediately fall back to control.
actor MobileHostIrohServerEventWriter: MobileHostIndependentEventWriting {
    typealias StreamOpener = @Sendable () async throws -> any CmxIrohSendStream

    private struct PendingOpen: Sendable {
        let id: UUID
        let task: Task<any CmxIrohSendStream, any Error>
    }

    private static let priority: Int32 = 50
    private let openStream: StreamOpener
    private let clock: any CmxIrohRelayClock
    private let sendTimeout: TimeInterval
    private var pendingOpen: PendingOpen?
    private var stream: (any CmxIrohSendStream)?
    private var streamID: UUID?
    private var sendInFlight = false
    private var closed = false

    init(
        session: CmxIrohAdmittedServerSession,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        sendTimeout: TimeInterval = 3
    ) {
        openStream = {
            try await session.openSendLane(
                .serverEvents(cursor: nil),
                priority: Self.priority
            )
        }
        self.clock = clock
        self.sendTimeout = sendTimeout
    }

    init(
        openStream: @escaping StreamOpener,
        clock: any CmxIrohRelayClock,
        sendTimeout: TimeInterval
    ) {
        self.openStream = openStream
        self.clock = clock
        self.sendTimeout = sendTimeout
    }

    func prepare() async throws {
        guard !closed else { throw MobileHostIrohServerEventWriterError.closed }
        if stream != nil { return }

        let pending: PendingOpen
        if let pendingOpen {
            pending = pendingOpen
        } else {
            let openStream = openStream
            let task = Task {
                try await openStream()
            }
            pending = PendingOpen(id: UUID(), task: task)
            pendingOpen = pending
        }

        do {
            let opened = try await pending.task.value
            if stream != nil { return }
            guard pendingOpen?.id == pending.id, !closed else {
                await opened.reset(errorCode: 1)
                throw MobileHostIrohServerEventWriterError.superseded
            }
            pendingOpen = nil
            stream = opened
            streamID = UUID()
        } catch {
            if pendingOpen?.id == pending.id {
                pendingOpen = nil
            }
            throw error
        }
    }

    func probe(_ framedData: Data) async -> Bool {
        do {
            try await prepare()
            if sendInFlight { return true }
            sendInFlight = true
            defer { sendInFlight = false }
            try await sendOnPreparedStream(framedData)
            return true
        } catch {
            return false
        }
    }

    func send(_ framedData: Data) async throws {
        try await prepare()
        guard !sendInFlight else {
            throw MobileHostIrohServerEventWriterError.concurrentSend
        }
        sendInFlight = true
        defer { sendInFlight = false }
        try await sendOnPreparedStream(framedData)
    }

    private func sendOnPreparedStream(_ framedData: Data) async throws {
        guard !closed, let activeStream = stream, let activeStreamID = streamID else {
            throw MobileHostIrohServerEventWriterError.closed
        }
        do {
            try await sendWithDeadline(framedData, stream: activeStream)
        } catch {
            if streamID == activeStreamID {
                stream = nil
                streamID = nil
            }
            await activeStream.reset(errorCode: 1)
            throw error
        }
    }

    func reset() async {
        pendingOpen?.task.cancel()
        pendingOpen = nil
        let previous = stream
        stream = nil
        streamID = nil
        await previous?.reset(errorCode: 1)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        pendingOpen?.task.cancel()
        pendingOpen = nil
        let previous = stream
        stream = nil
        streamID = nil
        await previous?.reset(errorCode: 0)
    }

    private func sendWithDeadline(
        _ data: Data,
        stream: any CmxIrohSendStream
    ) async throws {
        let clock = clock
        let deadline = clock.now().addingTimeInterval(sendTimeout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await stream.send(data)
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                await stream.reset(errorCode: 1)
                throw MobileHostIrohServerEventWriterError.sendTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MobileHostIrohServerEventWriterError.superseded
            }
            return result
        }
    }
}

private extension CmxIrohIdentityMaterial {
    var peerIdentity: CmxIrohPeerIdentity? {
        guard let privateKey = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: secretKey.bytes
        ) else { return nil }
        let endpointID = privateKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }
            .joined()
        return try? CmxIrohPeerIdentity(endpointID: endpointID)
    }
}

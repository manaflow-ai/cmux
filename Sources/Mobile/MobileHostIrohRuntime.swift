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

    private let appInstances = CmxIrohAppInstanceRepository()
    private let identities = CmxIrohIdentityRepository()
    private let brokerCredentials = CmxIrohBrokerCredentialRepository()
    private let hostPolicies = CmxIrohHostPolicyCache()
    private let authObserver = MobileHostIrohAuthObserver()

    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var runtime: CmxIrohHostRuntime?
    private var desiredActive = false
    private var observedAccountID: String?
    private var activeAccountID: String?
    private var activeAppInstanceID: String?
    private var lastKnownBindingID: String?
    private var lifecycleRevision: UInt64 = 0

    private init() {}

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, let self else { return }
            let states = self.authObserver.states(for: auth)
            for await state in states {
                guard !Task.isCancelled else { return }
                self.observedAccountID = state.accountID
                self.scheduleReconcile(eraseAccountState: state.accountID == nil)
            }
        }
    }

    func setDesiredActive(_ desired: Bool) {
        guard desiredActive != desired else {
            if desired { retryIfNeeded() }
            return
        }
        desiredActive = desired
        scheduleReconcile(eraseAccountState: false)
    }

    func retryIfNeeded() {
        guard desiredActive, observedAccountID != nil, runtime == nil else { return }
        scheduleReconcile(eraseAccountState: false)
    }

    /// Completes local teardown first, then best-effort revokes the old broker binding.
    func revokeAfterSignOut(
        accessToken: String?,
        refreshToken: String?
    ) async {
        observedAccountID = nil
        let bindingID = lastKnownBindingID
        let transition = scheduleReconcile(eraseAccountState: true)
        await transition.value

        guard let bindingID,
              let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else {
            lastKnownBindingID = nil
            return
        }
        do {
            let broker = try CmxIrohTrustBrokerClient(
                baseURL: AuthEnvironment.vmAPIBaseURL,
                tokenSource: CmxIrohBrokerTokenSource(
                    accessToken: { accessToken },
                    refreshToken: { refreshToken }
                )
            )
            try await broker.revoke(bindingID: bindingID)
        } catch {
            mobileHostIrohLog.error(
                "Iroh binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
        lastKnownBindingID = nil
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
                targetAccountID: self.desiredActive ? self.observedAccountID : nil,
                eraseAccountState: eraseAccountState,
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
        if activeAccountID != targetAccountID || targetAccountID == nil {
            let previousRuntime = runtime
            runtime = nil
            activeAccountID = nil
            activeAppInstanceID = nil
            await previousRuntime?.stop()
        }

        if eraseAccountState {
            do {
                try await hostPolicies.deactivate()
            } catch {
                mobileHostIrohLog.error(
                    "Iroh offline policy deletion failed: \(String(describing: error), privacy: .private)"
                )
            }
            try? await brokerCredentials.deactivate()
            try? await identities.deactivate()
            await appInstances.deactivate()
        }

        guard revision == lifecycleRevision,
              !Task.isCancelled,
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
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            displayName: MobileHostIdentity.displayName(),
            identity: identity,
            pairingEnabled: true,
            capabilities: Self.capabilities,
            bindPolicy: .ephemeral,
            managedRelayURLs: Self.managedRelayURLs,
            cachedRelayCredential: cachedRelay,
            cachedHostPolicy: cachedHostPolicy
        )
        let credentialRepository = brokerCredentials
        let hostPolicyCache = hostPolicies
        let managedRelayURLs = Self.managedRelayURLs
        let hostRuntime = CmxIrohHostRuntime(
            factory: CmxIrohLibEndpointFactory(),
            broker: broker,
            configuration: configuration,
            handleTransport: { session, isCurrent in
                await MobileHostService.acceptTransport(
                    session.controlTransport,
                    authorization: .irohAdmission(session.peer),
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
                            endpointAttestation: attestation
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
                    MobileHostService.shared.updateIrohBinding(binding)
                }
            },
            handleDeactivation: { bindingID in
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
            }
        )

        do {
            try await hostRuntime.start()
        } catch {
            await hostRuntime.stop()
            throw error
        }
        guard revision == lifecycleRevision,
              !Task.isCancelled,
              desiredActive,
              observedAccountID == accountID else {
            await hostRuntime.stop()
            throw CancellationError()
        }
        runtime = hostRuntime
        activeAccountID = accountID
        activeAppInstanceID = appInstanceID
    }

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

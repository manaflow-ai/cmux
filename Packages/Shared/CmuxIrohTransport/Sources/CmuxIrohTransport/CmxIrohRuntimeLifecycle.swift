import CMUXMobileCore
import Foundation

/// One lifecycle phase machine shared by the host and client runtimes.
enum CmxIrohRuntimeLifecyclePhase: Equatable, Sendable {
    case inactive, starting, active, stopping, signingOut, quarantined, failed

    var allowsStart: Bool { self == .inactive || self == .failed }

    var ownsNetworkOperation: Bool { self == .starting || self == .active }
}

/// Builds the terminal snapshots the shared sign-out flow settles into.
protocol CmxIrohRuntimeSnapshotRepresenting: Sendable {
    static func quarantined(bindingID: String?) -> Self
    static var inactive: Self { get }
}

extension CmxIrohHostRuntimeSnapshot: CmxIrohRuntimeSnapshotRepresenting {
    static func quarantined(bindingID: String?) -> Self {
        Self(state: .quarantined, endpointID: nil, bindingID: bindingID)
    }

    static var inactive: Self { Self(state: .inactive, endpointID: nil, bindingID: nil) }
}

extension CmxIrohClientRuntimeSnapshot: CmxIrohRuntimeSnapshotRepresenting {
    static func quarantined(bindingID: String?) -> Self {
        Self(state: .quarantined, endpointID: nil, bindingID: bindingID)
    }

    static var inactive: Self { Self(state: .inactive, endpointID: nil, bindingID: nil) }
}

/// Actor state both runtimes expose to the shared lifecycle helpers.
protocol CmxIrohRuntimeLifecycleManaging: Actor {
    associatedtype Binding
    associatedtype Snapshot: CmxIrohRuntimeSnapshotRepresenting

    var lifecyclePhase: CmxIrohRuntimeLifecyclePhase { get set }
    var lifecycleRevision: UInt64 { get }
    var localBinding: Binding? { get set }
    var lastRegistrationRefreshState: CmxIrohRegistrationPublicationState? { get set }
    var currentSnapshot: Snapshot { get set }
    var signOutOperation: Task<CmxIrohSignOutPreparation, Never>? { get set }
    var relayCoordinator: CmxIrohRelayCredentialCoordinator? { get set }
    var managedRelayURLs: Set<String> { get set }
    var pendingRevocations: CmxIrohPendingRevocationOutbox { get }
    func requireCurrent(_ revision: UInt64) throws
}

/// Queues one revocation device-side, reporting false only on outbox failure.
func cmxIrohPersistSignOutRevocation(
    _ revocation: CmxIrohPendingRevocation?,
    to pendingRevocations: CmxIrohPendingRevocationOutbox
) async -> Bool {
    guard let revocation else { return true }
    return (try? await pendingRevocations.enqueue(revocation)) != nil
}

extension CmxIrohRuntimeLifecycleManaging {
    /// Persists the revocation and tears down concurrently, then settles the phase.
    func performSignOutFlow(
        pendingRevocation: CmxIrohPendingRevocation?,
        bindingAuthorization: CmxIrohBindingRequestAuthorization?,
        revision: UInt64,
        tearDownNetwork: @escaping @Sendable () async -> Void,
        deactivateLocalState: (@Sendable () async -> Void)? = nil
    ) async -> CmxIrohSignOutPreparation {
        async let wasPersisted = cmxIrohPersistSignOutRevocation(
            pendingRevocation,
            to: pendingRevocations
        )
        async let networkTeardown: Void = tearDownNetwork()
        let (persisted, _) = await (wasPersisted, networkTeardown)
        let preparation = CmxIrohSignOutPreparation(
            pendingRevocation: pendingRevocation,
            wasPersisted: persisted,
            bindingAuthorization: bindingAuthorization
        )

        guard lifecyclePhase == .signingOut, lifecycleRevision == revision else {
            signOutOperation = nil
            return preparation
        }
        guard persisted else {
            lifecyclePhase = .quarantined
            currentSnapshot = .quarantined(bindingID: pendingRevocation?.bindingID)
            signOutOperation = nil
            return preparation
        }

        if let deactivateLocalState {
            await deactivateLocalState()
            guard lifecyclePhase == .signingOut, lifecycleRevision == revision else {
                signOutOperation = nil
                return preparation
            }
        }

        localBinding = nil
        lastRegistrationRefreshState = nil
        lifecyclePhase = .inactive
        currentSnapshot = .inactive
        signOutOperation = nil
        return preparation
    }

    /// Swaps the relay coordinator or installs a custom profile; the caller
    /// validates the fleet first and appends its role-specific tail.
    func swapRelayCoordinator(
        profile: CmxIrohEndpointRelayProfile,
        replacementManagedURLs: Set<String>,
        relayBootstrap: CmxIrohRelayTokenResponse?,
        role: CmxIrohRelayRefreshSchedule.Role,
        bindingID: String,
        endpointIdentity: CmxIrohPeerIdentity,
        connectivityEngine: CmxConnectivityEngine,
        broker: any CmxIrohRelayTokenServing,
        retrySchedule: CmxIrohRetrySchedule = CmxIrohRetrySchedule(),
        automaticRefreshEnabled: Bool = true,
        credentialDidInstall: @escaping @Sendable (CmxIrohRelayTokenResponse) async -> Void
    ) async throws -> UInt64 {
        let revision = lifecycleRevision

        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        if profile.source == .managed, !profile.allowedRelayURLs.isEmpty {
            let refreshSchedule = CmxIrohRelayRefreshSchedule(
                role: role,
                endpointIdentity: endpointIdentity
            )
            let coordinator = CmxIrohRelayCredentialCoordinator(
                supervisor: connectivityEngine,
                broker: broker,
                managedRelayURLs: replacementManagedURLs,
                selectedRelayURLs: profile.allowedRelayURLs,
                jitter: { now, refreshAfter in
                    refreshSchedule.deadline(now: now, refreshAfter: refreshAfter)
                },
                retrySchedule: retrySchedule,
                automaticRefreshEnabled: automaticRefreshEnabled,
                credentialDidInstall: credentialDidInstall
            )
            relayCoordinator = coordinator
            do {
                try await coordinator.activateManagedPolicy(
                    bindingID: bindingID,
                    endpointIdentity: endpointIdentity,
                    profile: profile,
                    bootstrap: relayBootstrap
                )
            } catch {
                await coordinator.deactivate()
                if relayCoordinator === coordinator {
                    relayCoordinator = nil
                }
                throw error
            }
        } else {
            try await connectivityEngine.replaceRelayProfile(
                profile,
                expectedIdentity: endpointIdentity
            )
        }
        try requireCurrent(revision)

        managedRelayURLs = replacementManagedURLs
        return revision
    }

    /// Returns whether the live authenticated endpoint advertises an allowed relay.
    func activeRelayReachability(
        in allowedRelayURLs: Set<String>,
        connectivityEngine: CmxConnectivityEngine?
    ) async -> Bool? {
        guard !allowedRelayURLs.isEmpty,
              lifecyclePhase == .active,
              let connectivityEngine,
              let address = try? await connectivityEngine.endpointAddress() else {
            return nil
        }
        return address.pathHints.contains {
            $0.kind == .relayURL && allowedRelayURLs.contains($0.value)
        }
    }
}

extension CmxIrohHostRuntime: CmxIrohRuntimeLifecycleManaging {}
extension CmxIrohClientRuntime: CmxIrohRuntimeLifecycleManaging {}

import CmuxAuthRuntime
import Foundation

extension Notification.Name {
    static let cmuxCloudTeamScopeDidChange = Notification.Name("cmux.cloudTeamScopeDidChange")
}

/// Reconciles local Cloud transports whenever the authenticated team changes.
/// The auth coordinator is the source of truth; this observer only coordinates
/// teardown and rediscovery at the app boundary.
@MainActor
final class CloudTeamScopeObserver {
    private let auth: AuthCoordinator
    private let registry: CmuxTuiSurfaceProviderRegistry
    private let onTeamWillChange: @MainActor () -> Void
    private var observationTask: Task<Void, Never>?

    init(
        auth: AuthCoordinator,
        registry: CmuxTuiSurfaceProviderRegistry = .shared,
        onTeamWillChange: @escaping @MainActor () -> Void
    ) {
        self.auth = auth
        self.registry = registry
        self.onTeamWillChange = onTeamWillChange
    }

    func start() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let auth = self.auth
            let registry = self.registry
            let onTeamWillChange = self.onTeamWillChange
            await auth.awaitBootstrapped()
            var previousTeamID: String?
            for await scope in auth.authenticatedTeamScopes() {
                guard !Task.isCancelled else { return }
                let nextTeamID = scope?.teamID
                guard nextTeamID != previousTeamID else { continue }
                let changedTeams = previousTeamID != nil && nextTeamID != nil
                previousTeamID = nextTeamID

                if changedTeams {
                    NotificationCenter.default.post(name: .cmuxCloudTeamScopeDidChange, object: self)
                    onTeamWillChange()
                }
                if nextTeamID == nil {
                    await registry.accessDidEnd()
                } else if changedTeams {
                    await registry.accessDidEnd()
                    await registry.resumeAfterSignIn()
                } else {
                    // Covers initial restore and sign-in when the registry was
                    // started before the auth session became ready.
                    await registry.resumeAfterSignIn()
                }
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}

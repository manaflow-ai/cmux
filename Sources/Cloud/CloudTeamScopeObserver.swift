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
    /// Registry teardown can wait for remote transports. Keep it out of the
    /// auth scope stream so a slow provider never prevents the next team
    /// selection from being observed. Requests are coalesced and reconciled in
    /// order against the latest authenticated scope.
    private var reconciliationTask: Task<Void, Never>?
    private var desiredScope: AuthenticatedTeamScope?
    private var desiredGeneration: UInt64 = 0
    private var needsTeardown = false
    private var needsResume = false

    init(
        auth: AuthCoordinator,
        registry: CmuxTuiSurfaceProviderRegistry? = nil,
        onTeamWillChange: @escaping @MainActor () -> Void
    ) {
        self.auth = auth
        self.registry = registry ?? .shared
        self.onTeamWillChange = onTeamWillChange
    }

    func start() {
        observationTask?.cancel()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.auth.awaitBootstrapped()
            var previousScope: AuthenticatedTeamScope?
            for await scope in self.auth.authenticatedTeamScopes() {
                guard !Task.isCancelled else { return }
                guard scope != previousScope else { continue }
                let changedTeams = previousScope != nil
                previousScope = scope

                if changedTeams {
                    self.onTeamWillChange()
                    NotificationCenter.default.post(name: .cmuxCloudTeamScopeDidChange, object: self)
                }
                self.requestReconciliation(
                    scope: scope,
                    requiresTeardown: scope == nil || changedTeams,
                    requiresResume: scope != nil
                )
            }
        }
    }

    private func requestReconciliation(
        scope: AuthenticatedTeamScope?,
        requiresTeardown: Bool,
        requiresResume: Bool
    ) {
        desiredScope = scope
        desiredGeneration &+= 1
        if requiresTeardown {
            needsTeardown = true
        }
        needsResume = requiresResume
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { @MainActor [weak self] in
            await self?.reconcileCloudScope()
        }
    }

    private func reconcileCloudScope() async {
        defer { reconciliationTask = nil }
        while !Task.isCancelled {
            let generation = desiredGeneration
            let scope = desiredScope
            if needsTeardown {
                await registry.accessDidEnd()
                // A newer scope may have arrived while teardown was waiting on
                // transports. The same teardown is sufficient for that scope;
                // the generation check below will move directly to resume.
                needsTeardown = false
            }
            guard generation == desiredGeneration else { continue }
            guard let scope else {
                needsResume = false
                return
            }
            guard !Task.isCancelled, auth.isAuthenticatedTeamScopeCurrent(scope) else { return }
            if needsResume {
                needsResume = false
                await registry.resumeAfterSignIn()
            }
            guard generation == desiredGeneration else { continue }
            guard auth.isAuthenticatedTeamScopeCurrent(scope) else { return }
            return
        }
    }

    deinit {
        observationTask?.cancel()
        reconciliationTask?.cancel()
    }
}

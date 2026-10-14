import CmuxAuthRuntime
import Foundation

/// Keeps the usage analytics identity in step with the Cloud session.
///
/// A signed-in session (fresh sign-in or a restored session at launch)
/// identifies analytics as the sign-in service user id, so the install's
/// anonymous events join the same person the web server records. Sign-out
/// resets analytics to a fresh anonymous id. The auth coordinator is the
/// source of truth; this observer only forwards account changes.
@MainActor
final class PostHogIdentityObserver {
    private let auth: AuthCoordinator
    private let analytics: PostHogAnalytics
    private var observationTask: Task<Void, Never>?

    init(auth: AuthCoordinator, analytics: PostHogAnalytics = .shared) {
        self.auth = auth
        self.analytics = analytics
    }

    func start() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Before restore finishes the coordinator can report a transient
            // signed-out state; acting on it would reset a valid identity.
            await self.auth.awaitBootstrapped()
            var previousAccountID: String??
            for await identity in self.auth.authenticatedSessionIdentities() {
                guard !Task.isCancelled else { return }
                let accountID = identity?.accountID
                guard accountID != previousAccountID else { continue }
                previousAccountID = .some(accountID)
                if let accountID {
                    self.analytics.identify(accountID: accountID)
                } else {
                    self.analytics.resetIdentity()
                }
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}

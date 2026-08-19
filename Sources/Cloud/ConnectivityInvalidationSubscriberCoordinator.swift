import CmuxAuthRuntime
import Foundation
import Observation

/// Mac composition wrapper for the shared account connectivity subscriber.
///
/// Mac composition wrapper for the account-scoped, revision-only protocol.
/// Mac and iPhone therefore run the exact same bounded parser, reconnect
/// policy, and cancellation path.
@MainActor
final class ConnectivityInvalidationSubscriberCoordinator {
    private struct Scope {
        let key: String
        let baseURL: URL
    }

    private weak var auth: AuthCoordinator?
    private var subscriber: MobileHostConnectivityInvalidationSubscriber?
    private var reconfigureTask: Task<Void, Never>?
    private var authObservationTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var activeScopeKey: String?

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.evaluate()
                }
            }
        }
        armAuthScopeObservation()
        evaluate()
    }

    private func armAuthScopeObservation() {
        guard let auth else { return }
        withObservationTracking {
            _ = auth.isAuthenticated
            _ = auth.currentUser?.id
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.authObservationTask?.cancel()
                self.authObservationTask = Task { @MainActor [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    self.evaluate()
                    self.armAuthScopeObservation()
                }
            }
        }
    }

    private func desiredScope() -> Scope? {
        guard let auth,
              auth.isAuthenticated,
              let userID = auth.currentUser?.id,
              let baseURL = PresenceHeartbeatClient.resolvedServiceURL()
        else { return nil }
        return Scope(
            key: "\(userID)|\(baseURL.absoluteString)",
            baseURL: baseURL
        )
    }

    private func evaluate() {
        let scope = desiredScope()
        guard scope?.key != activeScopeKey else { return }
        activeScopeKey = scope?.key
        reconfigureTask?.cancel()
        let previous = subscriber
        subscriber = nil
        let auth = auth
        reconfigureTask = Task { @MainActor [weak self] in
            await previous?.stop()
            guard !Task.isCancelled, let self, let scope else { return }
            let next = MobileHostConnectivityInvalidationSubscriber(
                serviceBaseURL: scope.baseURL,
                accessToken: { [weak auth] in
                    try? await auth?.accessToken()
                },
                handler: { invalidation in
                    await MainActor.run {
                        mobileHostPeerLog.info(
                            "Connectivity revision invalidated; reconciling authoritative routes"
                        )
                        MobileHostPeerRuntime.shared
                            .reconcileConnectivityFromServerSignal(
                                revision: invalidation.revision
                            )
                    }
                }
            )
            guard self.activeScopeKey == scope.key else { return }
            self.subscriber = next
            await next.start()
        }
    }

    func appWillTerminate() {
        authObservationTask?.cancel()
        authObservationTask = nil
        reconfigureTask?.cancel()
        let subscriber = subscriber
        self.subscriber = nil
        activeScopeKey = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        reconfigureTask = Task {
            await subscriber?.stop()
        }
    }
}

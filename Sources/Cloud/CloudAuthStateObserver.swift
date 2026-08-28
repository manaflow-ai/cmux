import CmuxAuthRuntime
import Foundation
import Observation

/// The auth scope the cloud discovery clients act in: whether a session is
/// published, which account owns it, and which team every registry/presence
/// request targets. `Equatable` so consumers can compare against the previous
/// yield and react only to real transitions (sign-in, account change, team
/// switch) instead of every observation tick.
struct CloudAuthObservedState: Equatable, Sendable {
    let isAuthenticated: Bool
    let userID: String?
    let teamID: String?
}

/// Observation-tracking bridge from ``CmuxAuthRuntime/AuthCoordinator`` to an
/// `AsyncStream`, mirroring `MobileHostIrohAuthObserver`: re-arms
/// `withObservationTracking` after every change so the stream yields whenever
/// `isAuthenticated`, the current user, or the resolved team moves. This is
/// what lets ``DeviceRegistryClient`` and ``PresenceHeartbeatClient`` react AT
/// the auth transition (register/beat immediately on sign-in, move teams on a
/// switch) instead of waiting for their next route tick or cadence beat.
@MainActor
final class CloudAuthStateObserver {
    private weak var auth: AuthCoordinator?
    private var continuation: AsyncStream<CloudAuthObservedState>.Continuation?

    func states(for auth: AuthCoordinator) -> AsyncStream<CloudAuthObservedState> {
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
            // User and team are read only while authenticated so a signed-out
            // coordinator always projects to one canonical state, whatever
            // stale identity fields it still carries mid-clear.
            CloudAuthObservedState(
                isAuthenticated: auth.isAuthenticated,
                userID: auth.isAuthenticated ? auth.currentUser?.id : nil,
                teamID: auth.isAuthenticated ? auth.resolvedTeamID : nil
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        continuation.yield(state)
    }
}

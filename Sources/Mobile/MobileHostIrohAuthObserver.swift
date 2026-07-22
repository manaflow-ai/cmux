import CmuxAuthRuntime
import Foundation
import Observation

struct MobileHostIrohAuthState: Equatable, Sendable {
    let accountID: String?
}

@MainActor
final class MobileHostIrohAuthObserver {
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

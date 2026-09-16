import CmuxAuthRuntime
import Foundation
import Observation

@MainActor
final class MobileHostIrohAuthObserver {
    private var readState: (@MainActor () -> MobileHostIrohAuthState)?
    private var continuation: AsyncStream<MobileHostIrohAuthState>.Continuation?
    private var generation = UUID()

    func states(for auth: AuthCoordinator) -> AsyncStream<MobileHostIrohAuthState> {
        states { [weak auth] in
            MobileHostIrohAuthState(accountID: auth?.isAuthenticated == true ? auth?.currentUser?.id : nil)
        }
    }

    /// Each subscription owns its observation and termination callbacks.
    func states(readState: @escaping @MainActor () -> MobileHostIrohAuthState) -> AsyncStream<MobileHostIrohAuthState> {
        stop()
        self.readState = readState
        let current = generation
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.stop()
                }
            }
            observe(generation: current)
        }
    }

    func stop() {
        let previous = continuation
        generation = UUID()
        continuation = nil
        readState = nil
        previous?.finish()
    }

    private func observe(generation current: UUID) {
        guard generation == current, let readState, let continuation else { return }
        let state = withObservationTracking {
            readState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(generation: current) }
        }
        continuation.yield(state)
    }
}

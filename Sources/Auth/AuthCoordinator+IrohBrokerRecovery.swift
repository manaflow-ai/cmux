import CmuxAuthRuntime
import CmuxIrohTransport

/// Shared auth-to-broker recovery seam used by both host transport runtimes.
@MainActor
extension AuthCoordinator {
    /// Force-mints the broker credential and preserves a definitive auth
    /// rejection for the host lifecycle instead of turning it into a retryable
    /// network error.
    func forceRefreshForIrohBroker() async throws {
        do {
            _ = try await forceRefreshAccessToken()
        } catch AuthError.unauthorized {
            throw CmxIrohBrokerTokenRecoveryError.authenticationRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CmxIrohBrokerTokenRecoveryError.transient
        }
    }
}

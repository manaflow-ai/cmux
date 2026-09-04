import CmuxAuthRuntime
import CmuxIrohTransport

/// Shared auth-to-broker recovery seam used by both host transport runtimes.
@MainActor
extension AuthCoordinator {
    /// Builds the account-pinned broker source used by both macOS host
    /// runtimes. The callbacks fence lifecycle ownership around the one
    /// refresh attempt: `forceRefreshAccessToken()` can publish a signed-out
    /// identity before its `unauthorized` error reaches the broker caller.
    /// Keeping that handoff here makes the account pin and recovery mapping
    /// identical for the legacy and irx stacks.
    func accountPinnedIrohBrokerTokenSource(
        accountID: String,
        onForceRefreshStart: (@Sendable () async -> Void)? = nil,
        onForceRefreshCompletion: (@Sendable (_ requiresReauthentication: Bool) async -> Void)? = nil
    ) -> CmxIrohBrokerTokenSource {
        .accountPinned(
            to: accountID,
            snapshot: { [weak self] in
                guard let self else { return nil }
                do {
                    let session = try await self.authenticatedSessionSnapshot()
                    return CmxIrohAccountCredentialSnapshot(
                        accountID: session.accountID,
                        credentials: CmxIrohBrokerCredentials(
                            accessToken: session.accessToken,
                            refreshToken: session.refreshToken
                        )
                    )
                } catch AuthError.unauthorized {
                    return nil
                }
            },
            forceRefresh: { [weak self] in
                guard let self else {
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
                await onForceRefreshStart?()
                do {
                    try await self.forceRefreshForIrohBroker()
                    await onForceRefreshCompletion?(false)
                } catch is CancellationError {
                    await onForceRefreshCompletion?(false)
                    throw CancellationError()
                } catch let error as CmxIrohBrokerTokenRecoveryError {
                    await onForceRefreshCompletion?(
                        error == .authenticationRequired
                    )
                    throw error
                } catch {
                    await onForceRefreshCompletion?(false)
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
            }
        )
    }

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

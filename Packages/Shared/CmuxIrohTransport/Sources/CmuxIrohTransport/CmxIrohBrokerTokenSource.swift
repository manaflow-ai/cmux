/// Supplies the short-lived Stack credentials required by native API calls.
///
/// The only construction input is `credentialPair`, which returns both tokens
/// from one capture and makes torn access/refresh pairs unrepresentable.
public struct CmxIrohBrokerTokenSource: Sendable {
    /// Captures both bearer credentials atomically for one request.
    public let credentialPair: @Sendable () async throws -> CmxIrohBrokerCredentials?
    /// Replaces a pair the broker just rejected. The broker request retries at
    /// most once with the returned pair.
    public let recoveredCredentialPair:
        @Sendable (_ rejected: CmxIrohBrokerCredentials) async throws
            -> CmxIrohBrokerCredentials?

    /// Creates a token source from atomic snapshot and recovery closures.
    public init(
        credentialPair: @escaping @Sendable () async throws -> CmxIrohBrokerCredentials?,
        recoveredCredentialPair: @escaping @Sendable (
            _ rejected: CmxIrohBrokerCredentials
        ) async throws -> CmxIrohBrokerCredentials? = { _ in nil }
    ) {
        self.credentialPair = credentialPair
        self.recoveredCredentialPair = recoveredCredentialPair
    }

    /// Builds a live token source pinned to one account.
    ///
    /// A rejected pair first re-reads the atomic session snapshot. If another
    /// lane already rotated it, that newer pair is reused. Otherwise the
    /// platform auth owner is asked to refresh once, followed by one final
    /// account-pinned snapshot. Account switches and missing sessions fail
    /// closed throughout.
    public static func accountPinned(
        to expectedAccountID: String,
        snapshot: @escaping @Sendable () async throws
            -> CmxIrohAccountCredentialSnapshot?,
        forceRefresh: @escaping @Sendable () async throws -> Void
    ) -> Self {
        Self(
            credentialPair: {
                guard let captured = try await snapshot(),
                      captured.accountID == expectedAccountID else {
                    return nil
                }
                return captured.credentials
            },
            recoveredCredentialPair: { rejected in
                do {
                    if let captured = try await snapshot(),
                       captured.accountID == expectedAccountID,
                       captured.credentials.accessToken != rejected.accessToken {
                        return captured.credentials
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CmxIrohBrokerTokenRecoveryError {
                    switch error {
                    case .authenticationRequired:
                        throw error
                    case .transient:
                        // A temporarily unavailable snapshot is precisely
                        // the case the explicit refresh below repairs.
                        break
                    }
                } catch {
                    // A transient snapshot read can still be repaired by the
                    // one explicit refresh below.
                }
                do {
                    try await forceRefresh()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CmxIrohBrokerTokenRecoveryError {
                    throw error
                } catch {
                    // Preserve an unknown auth-provider failure as transient.
                    // Returning nil would make the broker client replay the
                    // original 401 and misclassify a token-store/network blip
                    // as a definitive authorization rejection.
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
                let refreshed: CmxIrohAccountCredentialSnapshot?
                do {
                    refreshed = try await snapshot()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CmxIrohBrokerTokenRecoveryError {
                    throw error
                } catch {
                    // The refresh completed, but the rotated pair is not
                    // readable yet. Keep this on the bounded retry ladder;
                    // do not reissue the stale pair's 401.
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
                guard let refreshed,
                      refreshed.accountID == expectedAccountID else { return nil }
                return refreshed.credentials
            }
        )
    }
}

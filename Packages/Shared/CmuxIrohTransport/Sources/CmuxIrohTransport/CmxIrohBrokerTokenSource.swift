/// Supplies the short-lived Stack credentials required by native API calls.
///
/// The only construction input is `credentialPair`, which returns both tokens
/// from one capture and makes torn access/refresh pairs unrepresentable.
public struct CmxIrohBrokerTokenSource: Sendable {
    public let accessToken: @Sendable () async throws -> String?
    public let refreshToken: @Sendable () async throws -> String?
    public let credentialPair: @Sendable () async throws -> CmxIrohBrokerCredentials?
    /// Replaces a pair the broker just rejected. The broker request retries at
    /// most once with the returned pair.
    public let recoveredCredentialPair:
        @Sendable (_ rejected: CmxIrohBrokerCredentials) async throws
            -> CmxIrohBrokerCredentials?

    public init(
        credentialPair: @escaping @Sendable () async throws -> CmxIrohBrokerCredentials?,
        recoveredCredentialPair: @escaping @Sendable (
            _ rejected: CmxIrohBrokerCredentials
        ) async throws -> CmxIrohBrokerCredentials? = { _ in nil }
    ) {
        self.credentialPair = credentialPair
        self.recoveredCredentialPair = recoveredCredentialPair
        self.accessToken = { try await credentialPair()?.accessToken }
        self.refreshToken = { try await credentialPair()?.refreshToken }
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
                    throw error
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
                    return nil
                }
                let refreshed: CmxIrohAccountCredentialSnapshot?
                do {
                    refreshed = try await snapshot()
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CmxIrohBrokerTokenRecoveryError {
                    throw error
                } catch {
                    return nil
                }
                guard let refreshed,
                      refreshed.accountID == expectedAccountID else { return nil }
                return refreshed.credentials
            }
        )
    }
}

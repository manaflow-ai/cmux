import Foundation

extension AuthCoordinator {
    /// Permanently deletes the current Stack account through cmux's backend.
    ///
    /// Callers clear local shell/auth state through their normal sign-out owner
    /// after this succeeds so app-level teardown hooks run in the right order.
    public func deleteAccount() async throws -> AccountDeletionResult {
        let timeout = timeouts.network
        let tokens = try await accountDeletionTokens()
        return try await AccountDeletionClient(
            apiBaseURL: apiBaseURL,
            requestTimeout: timeout.urlRequestTimeoutInterval
        ).deleteAccount(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
    }

    /// Permanently deletes the current account and the data NEXT Cloud holds
    /// for it: `DELETE {cloudAPIBaseURL}/v1/me` (cmux-platform), which erases
    /// the NEXT Cloud data and then deletes the account and its sessions the
    /// way `deleteAccount()` does. A cloud origin that does not serve the
    /// route yet (404 or 501) gets `deleteAccount()` on cmux.com instead, so
    /// deletion never waits on a backend deploy.
    public func deleteAccount(cloudAPIBaseURL: String) async throws -> AccountDeletionResult {
        let timeout = timeouts.network.urlRequestTimeoutInterval
        let tokens = try await accountDeletionTokens()
        return try await deleteAccountPreferringCloud(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            cloud: AccountDeletionClient(
                apiBaseURL: cloudAPIBaseURL,
                path: AccountDeletionClient.cloudPath,
                unavailableStatusCodes: [404, 501],
                requestTimeout: timeout
            ),
            account: AccountDeletionClient(apiBaseURL: apiBaseURL, requestTimeout: timeout)
        )
    }

    private func accountDeletionTokens() async throws -> (accessToken: String, refreshToken: String) {
        try await runTokenTouchingPhase(.accountDeletion, timeout: timeouts.network) {
            try await self.currentTokens()
        }
    }
}

/// The cloud route first; the account route only when the cloud origin says
/// it does not serve deletion (no request reached a deletion there).
func deleteAccountPreferringCloud(
    accessToken: String,
    refreshToken: String,
    cloud: AccountDeletionClient,
    account: AccountDeletionClient
) async throws -> AccountDeletionResult {
    do {
        return try await cloud.deleteAccount(accessToken: accessToken, refreshToken: refreshToken)
    } catch is AccountDeletionRouteUnavailable {
        return try await account.deleteAccount(accessToken: accessToken, refreshToken: refreshToken)
    }
}

private extension Duration {
    var urlRequestTimeoutInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}

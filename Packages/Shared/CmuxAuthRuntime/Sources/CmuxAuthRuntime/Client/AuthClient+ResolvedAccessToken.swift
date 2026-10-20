extension AuthClient {
    /// Preserves compatibility for clients whose token reads have no typed failure.
    public func resolvedAccessToken(forceRefresh: Bool = false) async throws -> String? {
        try Task.checkCancellation()
        let token = await (forceRefresh ? forceRefreshAccessToken() : accessToken())
        try Task.checkCancellation()
        return token
    }
}

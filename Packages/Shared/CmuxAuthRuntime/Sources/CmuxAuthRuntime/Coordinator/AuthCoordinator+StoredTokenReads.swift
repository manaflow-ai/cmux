extension AuthCoordinator {
    /// Keeps a storage read's availability attached to its credentials.
    func readTokensForSessionCheck(includeAccessToken: Bool) async -> AuthStoredTokenRead {
        if let readStoredTokens { return await readStoredTokens() }
        // iOS protected data is unavailable until the first unlock. Preserve
        // the original pre/post checks for clients without an atomic reader.
        let availableBefore = await isTokenStorageAvailable()
        let access = includeAccessToken ? await client.accessToken() : nil
        let refresh = await client.refreshToken()
        let availableAfter = await isTokenStorageAvailable()
        return AuthStoredTokenRead(
            accessToken: access, refreshToken: refresh,
            isAvailable: availableBefore && availableAfter
        )
    }
}

@preconcurrency public import Foundation

extension ChromiumBrowserSession {
    /// Resolves all cmux-owned Chromium data for one logical browser profile.
    ///
    /// Callers must first stop every live pane using the profile, then remove
    /// the returned URL through their owned background file-removal service.
    /// Chromium holds exclusive locks inside each pane directory, so cleanup
    /// while a session is running would be incomplete and could destroy active
    /// state.
    ///
    /// - Parameters:
    ///   - profileID: Logical cmux browser profile to remove.
    ///   - environment: The same filesystem and namespace dependencies used
    ///     to construct the profile's sessions.
    public static func ownedProfileDataURL(
        for profileID: UUID,
        environment: ChromiumBrowserRuntimeEnvironment
    ) -> URL? {
        let storage = ChromiumOwnedStorage(
            fileManager: environment.fileManager,
            applicationSupportURLProvider: environment.applicationSupportURLProvider,
            bundleIdentifierProvider: environment.bundleIdentifierProvider
        )
        return try? storage.profileDirectoryURL(for: profileID)
    }
}

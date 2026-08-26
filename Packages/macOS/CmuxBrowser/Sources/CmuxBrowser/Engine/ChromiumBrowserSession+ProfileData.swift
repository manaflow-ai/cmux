@preconcurrency public import Foundation

extension ChromiumBrowserSession {
    /// Removes all cmux-owned Chromium data for one logical browser profile.
    ///
    /// Callers must first stop every live pane using the profile. Chromium
    /// holds exclusive locks inside each pane directory, so cleanup while a
    /// session is running would be incomplete and could destroy active state.
    ///
    /// - Parameters:
    ///   - profileID: Logical cmux browser profile to remove.
    ///   - environment: The same filesystem and namespace dependencies used
    ///     to construct the profile's sessions.
    public static func removeOwnedProfileData(
        for profileID: UUID,
        environment: ChromiumBrowserRuntimeEnvironment
    ) {
        let storage = ChromiumOwnedStorage(
            fileManager: environment.fileManager,
            applicationSupportURLProvider: environment.applicationSupportURLProvider,
            bundleIdentifierProvider: environment.bundleIdentifierProvider
        )
        guard let directory = try? storage.profileDirectoryURL(for: profileID) else { return }
        try? environment.fileManager.removeItem(at: directory)
    }
}

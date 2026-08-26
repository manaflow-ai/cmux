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

    /// Removes the resolved profile directory on a utility task.
    ///
    /// The URL is resolved before the task is detached; the detached closure
    /// captures only this value and uses Foundation's thread-safe file
    /// manager, so a large Chromium cache cannot block the AppKit actor.
    public static func removeOwnedProfileData(
        for profileID: UUID,
        environment: ChromiumBrowserRuntimeEnvironment
    ) async {
        guard let directory = ownedProfileDataURL(for: profileID, environment: environment) else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }
}

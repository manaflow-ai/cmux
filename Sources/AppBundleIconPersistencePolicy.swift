import Foundation

enum AppBundleIconPersistencePolicy {
    private static let stableReleaseBundleIdentifier = "com.cmuxterm.app"
    private static let stableReleaseAppBundleName = "cmux.app"
    static let disablePersistenceArgument = "--cmux-disable-bundle-icon-persistence"

    static func shouldPersist(
        bundleIdentifier: String?,
        appBundleLastPathComponent: String?,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard !launchArguments.contains(disablePersistenceArgument) else {
            return false
        }

        // Channel variants own their identity through build-time bundle metadata.
        // Persisted Finder icons would override that metadata and can leak into
        // packaged artifacts after CI smoke launches the app bundle.
        return bundleIdentifier == stableReleaseBundleIdentifier
            && appBundleLastPathComponent == stableReleaseAppBundleName
    }
}

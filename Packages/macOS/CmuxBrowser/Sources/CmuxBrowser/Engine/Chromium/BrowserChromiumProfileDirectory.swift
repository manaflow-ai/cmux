public import Foundation

/// Resolves persistent Chromium storage owned by one cmux browser profile.
public struct BrowserChromiumProfileDirectory: Sendable {
    private let applicationSupportDirectory: URL
    private let bundleIdentifier: String

    /// Creates a profile-directory resolver over explicit application storage.
    ///
    /// - Parameters:
    ///   - applicationSupportDirectory: The user Application Support directory.
    ///   - bundleIdentifier: The running app's bundle identifier.
    public init(applicationSupportDirectory: URL, bundleIdentifier: String) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.bundleIdentifier = bundleIdentifier
    }

    /// Returns the persistent Chromium user-data directory for one cmux profile.
    ///
    /// Tagged debug and staging builds share their normalized cmux namespace so
    /// a profile survives tagged rebuilds in the same lane.
    ///
    /// - Parameter profileID: The cmux browser profile identifier.
    /// - Returns: A stable directory unique to that profile and build lane.
    public func url(profileID: UUID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent(
                BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: bundleIdentifier),
                isDirectory: true
            )
            .appendingPathComponent("browser_profiles", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("chromium", isDirectory: true)
    }
}

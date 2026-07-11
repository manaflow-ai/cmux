/// Filesystem seam used to discover Android SDK components without touching disk in tests.
public protocol AndroidSDKFileChecking: Sendable {
    /// Whether `path` exists as a directory.
    func directoryExists(atPath path: String) -> Bool

    /// Whether `path` exists and is executable by the current user.
    func executableExists(atPath path: String) -> Bool
}

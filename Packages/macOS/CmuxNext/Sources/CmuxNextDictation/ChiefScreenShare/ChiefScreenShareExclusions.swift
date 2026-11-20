public import Foundation

/// The apps whose windows never reach a frame shared with the Chief: cmux itself (every build, so
/// the Chief's own chat never echoes back) and the password managers.
public struct ChiefScreenShareExclusions: Sendable, Equatable {
    /// Password managers and keychains, by bundle id.
    public static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane",
        "com.lastpass.LastPass", "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
    ]
    /// Bundle id prefix of every cmux build (Release, NIGHTLY, tagged DEV builds).
    public static let cmuxPrefix = "com.cmuxterm."

    /// The excluded bundle ids.
    public var bundleIDs: Set<String>
    /// This app's process, always excluded.
    public var ownProcess: pid_t

    /// - Parameters:
    ///   - bundleIDs: The excluded bundle ids; cmux builds are excluded whatever this holds.
    ///   - ownProcess: This app's process.
    public init(bundleIDs: Set<String> = Self.passwordManagers, ownProcess: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.bundleIDs = bundleIDs
        self.ownProcess = ownProcess
    }

    /// Whether the app with `bundleID` running as `processID` is left out of every frame.
    ///
    /// - Parameters:
    ///   - bundleID: The app's bundle id, nil when it has none.
    ///   - processID: The app's process.
    /// - Returns: True for this app, any cmux build and the listed apps.
    public func excludes(bundleID: String?, processID: pid_t) -> Bool {
        if processID == ownProcess { return true }
        guard let bundleID else { return false }
        return bundleID.hasPrefix(Self.cmuxPrefix) || bundleIDs.contains(bundleID)
    }
}

public import Foundation

/// Native-messaging host folders that Chromium should search in addition to
/// the cmux profile folders supplied by the CEF fork.
///
/// Chrome extensions commonly register their native host only with Google
/// Chrome. Searching the same user and system folders lets those extensions
/// keep working in cmux while Chromium still enforces each host manifest's
/// `allowed_origins`.
public struct CEFNativeMessagingFolder: Equatable, Sendable {
    /// The native-messaging host folder.
    public let path: String
    /// Whether Chromium treats the folder as user-level policy.
    public let isUserLevel: Bool

    /// Creates a native-messaging host folder description.
    public init(path: String, isUserLevel: Bool) {
        self.path = path
        self.isUserLevel = isUserLevel
    }
}

/// Resolves the Google Chrome native-messaging folders used by CEF.
public struct CEFNativeMessaging: Sendable {
    /// Creates a folder resolver.
    public init() {}

    /// Returns Google Chrome's user and system host folders for `home`.
    ///
    /// - Parameter home: The home directory whose user-level folder is used.
    /// - Returns: User-level and system-level folders in Chromium's lookup
    ///   order.
    public func googleChromeFolders(home: URL) -> [CEFNativeMessagingFolder] {
        [
            CEFNativeMessagingFolder(
                path: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts").path,
                isUserLevel: true
            ),
            CEFNativeMessagingFolder(
                path: "/Library/Google/Chrome/NativeMessagingHosts",
                isUserLevel: false
            ),
        ]
    }
}

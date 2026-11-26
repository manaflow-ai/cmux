public import Foundation

/// Reads another app's preferences domain, such as `com.googlecode.iterm2`.
public protocol TerminalPreferencesReading: Sendable {
    /// The domain's key-value pairs, or `nil` when the app has no preferences.
    ///
    /// - Parameter domain: The preferences domain (bundle identifier).
    func preferences(forDomain domain: String) -> [String: Any]?
}

/// Reads preferences through `cfprefsd`, falling back to the plist in `~/Library/Preferences`.
public struct SystemTerminalPreferencesReader: TerminalPreferencesReading {
    private let homeDirectory: URL

    /// Creates a reader.
    ///
    /// - Parameter homeDirectory: The home whose `Library/Preferences` is the fallback.
    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    /// The domain from `cfprefsd`, which includes unflushed changes, else from its plist file.
    public func preferences(forDomain domain: String) -> [String: Any]? {
        let live = CFPreferencesCopyMultiple(
            nil,
            domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any]
        if let live, !live.isEmpty {
            return live
        }
        let url = homeDirectory
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(domain).plist", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

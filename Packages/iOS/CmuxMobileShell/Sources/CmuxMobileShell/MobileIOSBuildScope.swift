public import Foundation

/// Identifies the running iOS app build for local paired-Mac scoping.
///
/// Tagged DEBUG installs have distinct bundle ids and home-screen labels.
/// Storage follows the installed bundle suffix so equivalent raw tags that
/// sanitize to the same bundle id also share the same saved-Mac scope. Release
/// builds intentionally return `nil` so they keep the stable, unscoped saved-Mac
/// list.
public struct MobileIOSBuildScope: Sendable, Equatable {
    public var value: String

    public init?(_ rawValue: String?) {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    public static func current(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> MobileIOSBuildScope? {
        let prefix = "dev.cmux.ios."
        if let bundleIdentifier,
           bundleIdentifier.hasPrefix(prefix),
           let scope = MobileIOSBuildScope(String(bundleIdentifier.dropFirst(prefix.count))) {
            return scope
        }

        if let value = infoDictionary?["CMUXDevTag"] as? String,
           let scope = MobileIOSBuildScope(value),
           scope.value != "default" {
            return scope
        }

        return nil
    }

    public var storageComponent: String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public var serializedScope: String {
        "ios:\(storageComponent)"
    }
}

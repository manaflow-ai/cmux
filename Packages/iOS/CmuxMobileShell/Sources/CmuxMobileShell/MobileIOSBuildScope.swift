public import Foundation

/// Identifies the running iOS app build for local paired-Mac scoping.
///
/// Tagged DEBUG installs have distinct bundle ids and home-screen labels, but
/// the tag is the human and build-system identity users reason about. Release
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
        if let value = infoDictionary?["CMUXDevTag"] as? String,
           let scope = MobileIOSBuildScope(value),
           scope.value != "default" {
            return scope
        }

        let prefix = "dev.cmux.ios."
        if let bundleIdentifier,
           bundleIdentifier.hasPrefix(prefix),
           let scope = MobileIOSBuildScope(String(bundleIdentifier.dropFirst(prefix.count))) {
            return scope
        }

        return nil
    }

    public var storageComponent: String {
        value
            .lowercased()
            .unicodeScalars
            .map { scalar in
                let value = scalar.value
                let isLowercaseLetter = value >= 97 && value <= 122
                let isNumber = value >= 48 && value <= 57
                return (isLowercaseLetter || isNumber || scalar == "-" || scalar == "_")
                    ? Character(scalar)
                    : "-"
            }
            .reduce(into: "") { $0.append($1) }
    }
}

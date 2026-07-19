public import Foundation

/// Identifies one tagged iOS development build.
///
/// The canonical tag owns the iOS saved-Mac and backup partitions. The Mac app
/// instance used for route authority is resolved separately because a tagged
/// `--prod-auth` iOS build pairs with a stable/beta Mac whose tag is `default`.
/// Stable and untagged iOS builds have no scope, so they keep the legacy
/// device-level behavior instead of manufacturing a tagged identity.
public struct MobileIOSBuildScope: Sendable, Equatable {
    private static let serializedScopeVersion = "v2"

    /// The canonical iOS development tag.
    public let value: String

    /// Creates a tagged-build scope, or returns `nil` for stable/untagged input.
    ///
    /// - Parameter rawValue: The canonical development tag.
    public init?(_ rawValue: String?) {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.lowercased() != "default" else { return nil }
        self.value = trimmed
    }

    /// Resolves the scope owned by the running iOS app bundle.
    ///
    /// - Parameters:
    ///   - infoDictionary: The app bundle metadata containing `CMUXDevTag`.
    ///   - bundleIdentifier: The installed iOS app's bundle identifier.
    /// - Returns: A tag scope for a development build, or `nil` for stable.
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
           let scope = MobileIOSBuildScope(value) {
            return scope
        }

        return nil
    }

    /// A filesystem- and header-safe encoding of ``value``.
    public var storageComponent: String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The paired-Mac backup client scope shared with the matching Mac build.
    ///
    /// The version is part of the storage namespace. The unversioned namespace
    /// was populated from shared device-level data by older development builds,
    /// so reading it would reintroduce cross-build routes after an upgrade.
    public var serializedScope: String {
        "ios:\(Self.serializedScopeVersion):\(storageComponent)"
    }

    /// Presentation name for a Mac shown by this tagged iOS build.
    ///
    /// The suffix comes from the running iOS bundle, so restored or offline
    /// device-level records remain distinguishable before a host handshake.
    ///
    /// - Parameter baseName: The stable physical-device name.
    /// - Returns: The name suffixed with the development tag exactly once.
    public func computerDisplayName(_ baseName: String) -> String {
        let suffix = " (\(value))"
        return baseName.hasSuffix(suffix) ? baseName : baseName + suffix
    }
}

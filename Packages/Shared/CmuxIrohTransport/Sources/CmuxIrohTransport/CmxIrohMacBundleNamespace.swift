import Foundation

/// Broker namespace owned by one exact installed macOS app bundle.
public struct CmxIrohMacBundleNamespace: Equatable, Hashable, Sendable {
    /// Canonical `mac:<bundle-id>` value sent to the trust broker.
    public let rawValue: String

    /// Creates a namespace from one complete macOS bundle identifier.
    public init?(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return nil }
        let trimmed = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed == bundleIdentifier,
              trimmed.contains("."),
              trimmed.utf8.count <= 251,
              trimmed.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        let value = "mac:\(trimmed.lowercased())"
        guard cmxIrohIsSafeToken(value, maximumUTF8ByteCount: 255) else {
            return nil
        }
        rawValue = value
    }
}

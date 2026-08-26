import Foundation

/// Channel namespace owned by one exact installed macOS app bundle, reported
/// to phones in authenticated host status as `mac_client_namespace`
/// (`mac:<bundle-id>`). Development phone builds fail closed without it
/// (`MobileMacBuildCompatibilityPolicy.allowsAuthenticatedHost`), so the Mac
/// must keep reporting it regardless of which transport carried the session.
struct MobileHostBundleNamespace: Equatable, Hashable, Sendable {
    /// Canonical `mac:<bundle-id>` value.
    let rawValue: String

    /// Creates a namespace from one complete macOS bundle identifier.
    init?(bundleIdentifier: String?) {
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
        rawValue = "mac:\(trimmed.lowercased())"
    }
}

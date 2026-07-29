import Foundation

/// Immutable isolation boundary for one installed cmux iOS application.
///
/// The complete bundle identifier is the namespace. Distribution labels and
/// short development tags are deliberately not accepted here because either
/// can alias another installed app.
public struct MobileIOSAppNamespace: Equatable, Hashable, Sendable {
    public let bundleIdentifier: String

    public init?(bundleIdentifier: String?) {
        guard let bundleIdentifier else { return nil }
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == bundleIdentifier,
              trimmed.count <= 255,
              trimmed.contains("."),
              trimmed.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                options: .regularExpression
              ) != nil
        else {
            return nil
        }
        self.bundleIdentifier = trimmed
    }

    /// The exact Keychain access group this app must claim after signing.
    public func keychainAccessGroup(teamIdentifier: String) -> String {
        "\(teamIdentifier).\(bundleIdentifier)"
    }

    /// A Keychain service that cannot collide with another installed bundle.
    public func keychainService(base: String) -> String {
        "\(base).\(bundleIdentifier)"
    }

    /// The only pairing URL scheme this bundle registers with iOS.
    public var pairingURLScheme: String {
        "cmux-ios-\(bundleIdentifier)"
    }

    /// Opaque server partition for data restored to this exact app bundle.
    public var serverScope: String {
        let encoded = Data(bundleIdentifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "ios:v3:\(encoded)"
    }
}

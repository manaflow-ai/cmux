import Foundation

/// Immutable isolation boundary for one installed cmux iOS application.
///
/// The complete bundle identifier is the namespace. Distribution labels and
/// short development tags are deliberately not accepted here because either
/// can alias another installed app.
public struct MobileIOSAppNamespace: Equatable, Hashable, Sendable {
    /// Exact bundle identifier that owns this namespace.
    public let bundleIdentifier: String

    /// Creates a namespace from one complete, validated iOS bundle identifier.
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

    /// Resolves the exact iOS bundle paired with one Mac app instance.
    ///
    /// Tagged Mac builds pair with the same tagged iOS development bundle.
    /// The stable Mac instance pairs with the public App Store bundle. Invalid
    /// tags fail closed instead of aliasing another installed iOS app.
    public init?(pairedMacInstanceTag instanceTag: String?) {
        let tag = instanceTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let instanceTag, instanceTag != tag {
            return nil
        }
        let bundleIdentifier = if tag.isEmpty || tag == "default" {
            "com.cmux.app"
        } else {
            "dev.cmux.ios.\(tag)"
        }
        self.init(bundleIdentifier: bundleIdentifier)
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

    /// The private OAuth callback scheme used only by this app's browser flow.
    public var oauthCallbackURLScheme: String {
        "cmux-ios-auth-\(bundleIdentifier)"
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

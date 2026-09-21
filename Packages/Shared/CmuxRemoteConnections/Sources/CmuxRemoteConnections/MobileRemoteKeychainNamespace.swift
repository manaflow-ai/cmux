import Foundation

/// Exact Keychain service and access-group namespace claimed by a signed target.
public struct MobileRemoteKeychainNamespace: Equatable, Hashable, Sendable {
    /// The package's versioned service name; it contains no host or account data.
    public static let defaultService = "dev.cmux.remote.secret.v1"

    /// Exact access group from the signed target's entitlement.
    public let accessGroup: String
    /// Versioned service identifier shared by this app's secret records.
    public let service: String

    /// Creates a namespace for one signed application target.
    ///
    /// - Parameter accessGroup: The fully-qualified signed access group, for example
    ///   `TEAMID.dev.cmux.ios`. Wildcards and build-setting placeholders are rejected.
    /// - Throws: ``MobileRemoteSecretStoreError/invalidNamespace`` for an imprecise namespace.
    public init(accessGroup: String) throws {
        guard Self.isExactAttribute(accessGroup), !accessGroup.contains("*") else {
            throw MobileRemoteSecretStoreError.invalidNamespace
        }
        self.accessGroup = accessGroup
        self.service = Self.defaultService
    }

    private static func isExactAttribute(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 255
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !value.contains("$(")
    }
}

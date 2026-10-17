import Foundation

/// What a ``CloudSecretVault/set(_:scope:source:)`` or ``CloudSecretVault/remove(names:scope:)``
/// did to one name.
public struct CloudSecretChange: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case added, updated, unchanged, removed
    }

    public let name: String
    public let scope: CloudSecretScope
    public let kind: Kind

    public init(name: String, scope: CloudSecretScope, kind: Kind) {
        self.name = name
        self.scope = scope
        self.kind = kind
    }
}

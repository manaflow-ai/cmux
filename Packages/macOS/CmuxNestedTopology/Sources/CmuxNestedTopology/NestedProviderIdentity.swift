/// Compound identity for one nested-provider connection generation.
public struct NestedProviderIdentity: Codable, Hashable, Sendable {
    /// Provider implementation kind.
    public let kind: NestedProviderKind

    /// Provider instance and connection generation.
    public let instanceID: NestedProviderInstanceID

    /// Creates a compound provider identity.
    ///
    /// - Parameters:
    ///   - kind: Provider implementation kind.
    ///   - instanceID: Provider instance and generation.
    public init(kind: NestedProviderKind, instanceID: NestedProviderInstanceID) {
        self.kind = kind
        self.instanceID = instanceID
    }
}

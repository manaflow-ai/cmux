/// Identifies which nested-multiplexer provider owns a topology tree.
///
/// Raw provider node IDs are only meaningful within one ``NestedProviderKind``
/// and one ``NestedProviderInstanceID``.
public enum NestedProviderKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Herdr nested multiplexer.
    case herdr
}

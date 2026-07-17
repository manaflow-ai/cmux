/// Describes the concrete Git object used as a changes baseline.
public struct ChangesBaseInfo: Sendable, Equatable {
    /// The baseline selection mode.
    public let kind: ChangesBaseKind
    /// The fully resolved Git object identifier used by `git diff`.
    public let resolvedRef: String
    /// A compact technical description of the source reference.
    public let describe: String

    /// Creates baseline metadata.
    /// - Parameters:
    ///   - kind: The baseline selection mode.
    ///   - resolvedRef: The concrete Git object identifier.
    ///   - describe: A compact technical description of the source.
    public init(kind: ChangesBaseKind, resolvedRef: String, describe: String) {
        self.kind = kind
        self.resolvedRef = resolvedRef
        self.describe = describe
    }
}

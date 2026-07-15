/// The concrete Git object selected for a comparison.
public struct DiffBaseInfo: Sendable, Codable, Equatable {
    /// The requested baseline kind.
    public let kind: DiffBaseKind
    /// The resolved Git object identifier used by diff commands.
    public let resolvedRef: String
    /// A concise description suitable for a diff header.
    public let describe: String

    /// Creates resolved baseline metadata.
    /// - Parameters:
    ///   - kind: The requested baseline kind.
    ///   - resolvedRef: The Git object identifier used by diff commands.
    ///   - describe: A concise human-readable description.
    public init(kind: DiffBaseKind, resolvedRef: String, describe: String) {
        self.kind = kind
        self.resolvedRef = resolvedRef
        self.describe = describe
    }
}

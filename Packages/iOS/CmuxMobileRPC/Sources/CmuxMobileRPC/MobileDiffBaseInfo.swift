/// The resolved baseline returned by a workspace-diff summary.
public struct MobileDiffBaseInfo: Codable, Sendable, Equatable {
    /// The requested baseline strategy.
    public let kind: MobileDiffBaseKind
    /// The concrete Git object used for the comparison.
    public let resolvedRef: String
    /// A concise description of the resolved baseline.
    public let describe: String

    /// Creates resolved baseline metadata.
    /// - Parameters:
    ///   - kind: The requested baseline strategy.
    ///   - resolvedRef: The concrete Git object used for the comparison.
    ///   - describe: A concise baseline description.
    public init(kind: MobileDiffBaseKind, resolvedRef: String, describe: String) {
        self.kind = kind
        self.resolvedRef = resolvedRef
        self.describe = describe
    }
}

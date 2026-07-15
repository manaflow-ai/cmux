/// Selects the baseline for a workspace-diffs request.
public struct MobileDiffBaseSpec: Codable, Sendable, Equatable {
    /// The requested baseline strategy.
    public let kind: MobileDiffBaseKind
    /// An optional baseline value, such as a branch override.
    public let value: String?

    /// Creates a workspace-diffs baseline selection.
    /// - Parameters:
    ///   - kind: The requested baseline strategy.
    ///   - value: An optional baseline value.
    public init(kind: MobileDiffBaseKind, value: String? = nil) {
        self.kind = kind
        self.value = value
    }
}

/// Describes the baseline requested by a diff caller.
public struct DiffBaseSpec: Sendable, Codable, Equatable {
    /// The baseline selection strategy.
    public let kind: DiffBaseKind
    /// A resolved last-turn commit or an optional branch override.
    public let value: String?

    /// Creates a baseline specification.
    /// - Parameters:
    ///   - kind: The baseline selection strategy.
    ///   - value: For `lastTurn`, the resolved baseline object; for `branchBase`, an optional branch ref.
    public init(kind: DiffBaseKind, value: String? = nil) {
        self.kind = kind
        self.value = value
    }
}

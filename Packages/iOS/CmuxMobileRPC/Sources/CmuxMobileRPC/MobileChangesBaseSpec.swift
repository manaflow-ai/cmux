/// Describes the baseline for a mobile workspace-changes request.
public struct MobileChangesBaseSpec: Codable, Sendable, Equatable {
    /// The baseline strategy sent as `kind` on the wire.
    public let kind: MobileChangesBaseKind
    /// An optional branch or future baseline value understood by the selected strategy.
    public let value: String?

    /// Creates a changes baseline specification.
    /// - Parameters:
    ///   - kind: The baseline strategy.
    ///   - value: An optional strategy-specific value, such as an explicit branch name.
    public init(kind: MobileChangesBaseKind, value: String? = nil) {
        self.kind = kind
        self.value = value
    }
}

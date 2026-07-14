/// Reports the baseline resolved by the Mac for a changes summary.
public struct MobileChangesBaseInfo: Codable, Sendable, Equatable {
    /// The requested baseline strategy.
    public let kind: MobileChangesBaseKind
    /// The concrete Git reference selected by the engine.
    public let resolvedRef: String
    /// A concise description suitable for later presentation by the UI layer.
    public let describe: String

    /// Creates resolved baseline information.
    /// - Parameters:
    ///   - kind: The requested baseline strategy.
    ///   - resolvedRef: The concrete Git reference selected by the engine.
    ///   - describe: A concise description of the resolved baseline.
    public init(kind: MobileChangesBaseKind, resolvedRef: String, describe: String) {
        self.kind = kind
        self.resolvedRef = resolvedRef
        self.describe = describe
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case resolvedRef = "resolved_ref"
        case describe
    }
}

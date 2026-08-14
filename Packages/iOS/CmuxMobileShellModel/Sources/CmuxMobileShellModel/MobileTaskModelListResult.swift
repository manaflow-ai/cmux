/// Models returned by the Mac and the strategy that produced them.
public struct MobileTaskModelListResult: Equatable, Sendable {
    /// Models in composer display order.
    public let models: [MobileTaskAgentModel]
    /// Whether the list was discovered, supplied by the backend, or unavailable.
    public let source: MobileTaskModelListSource

    /// Creates a task model list result.
    ///
    /// - Parameters:
    ///   - models: Models in composer display order.
    ///   - source: Strategy that produced the list.
    public init(
        models: [MobileTaskAgentModel],
        source: MobileTaskModelListSource
    ) {
        self.models = models
        self.source = source
    }
}

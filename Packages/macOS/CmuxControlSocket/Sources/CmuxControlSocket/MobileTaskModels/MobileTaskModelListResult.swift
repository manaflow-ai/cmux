/// A task provider's models and the strategy that produced them.
public struct MobileTaskModelListResult: Equatable, Sendable {
    /// Models in composer display order.
    public let models: [MobileTaskModel]
    /// Whether the list was discovered, supplied by the backend, or unavailable.
    public let source: MobileTaskModelListSource

    /// Creates a task model list result.
    ///
    /// - Parameters:
    ///   - models: Models in composer display order.
    ///   - source: Strategy that produced the list.
    public init(
        models: [MobileTaskModel],
        source: MobileTaskModelListSource
    ) {
        self.models = models
        self.source = source
    }
}

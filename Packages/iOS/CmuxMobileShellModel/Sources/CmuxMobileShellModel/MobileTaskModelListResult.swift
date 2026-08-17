/// Models returned by the Mac and the strategy that produced them.
public struct MobileTaskModelListResult: Equatable, Sendable {
    /// Models in composer display order.
    public let models: [MobileTaskAgentModel]
    /// Metadata for the provider's implicit Default selection. This is kept
    /// separate from `models` because Default must not become an explicit
    /// model argument in a task command.
    public let defaultModel: MobileTaskAgentModel?
    /// Whether the list was discovered, supplied by the backend, or unavailable.
    public let source: MobileTaskModelListSource

    /// Creates a task model list result.
    ///
    /// - Parameters:
    ///   - models: Models in composer display order.
    ///   - source: Strategy that produced the list.
    ///   - defaultModel: Metadata for the implicit Default selection.
    public init(
        models: [MobileTaskAgentModel],
        source: MobileTaskModelListSource,
        defaultModel: MobileTaskAgentModel? = nil
    ) {
        self.models = models
        self.source = source
        self.defaultModel = defaultModel
    }
}

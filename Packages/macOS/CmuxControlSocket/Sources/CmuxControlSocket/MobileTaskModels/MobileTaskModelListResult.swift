/// Why a provider model catalog could not be read.
public enum MobileTaskModelListError: String, Equatable, Sendable {
    /// The provider executable is not available in the Mac user's login PATH.
    case providerUnavailable = "provider_unavailable"
    /// The provider was present, but its catalog command failed or returned no usable values.
    case queryFailed = "query_failed"
}

/// A task provider's models and the strategy that produced them.
public struct MobileTaskModelListResult: Equatable, Sendable {
    /// Models in composer display order.
    public let models: [MobileTaskModel]
    /// Metadata for the provider's implicit Default selection. This is kept
    /// separate from `models` because Default must not become an explicit
    /// model argument in a task command.
    public let defaultModel: MobileTaskModel?
    /// Whether the list was discovered, supplied by the backend, or unavailable.
    public let source: MobileTaskModelListSource
    /// A provider discovery error, when no authoritative values were available.
    public let error: MobileTaskModelListError?

    /// Creates a task model list result.
    ///
    /// - Parameters:
    ///   - models: Models in composer display order.
    ///   - source: Strategy that produced the list.
    ///   - defaultModel: Metadata for the implicit Default selection.
    ///   - error: Provider discovery failure, when applicable.
    public init(
        models: [MobileTaskModel],
        source: MobileTaskModelListSource,
        defaultModel: MobileTaskModel? = nil,
        error: MobileTaskModelListError? = nil
    ) {
        self.models = models
        self.source = source
        self.defaultModel = defaultModel
        self.error = error
    }
}

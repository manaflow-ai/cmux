/// The effective model list and validation policy for one task template.
public struct MobileTaskModelAvailability: Sendable {
    /// Provider detected from the template command.
    public let provider: MobileTaskAgentProvider?
    /// Models shown by the composer.
    public let models: [MobileTaskAgentModel]
    /// Metadata for the provider's implicit Default selection.
    public let defaultModel: MobileTaskAgentModel?

    /// Resolves only runtime-supplied models.
    ///
    /// - Parameters:
    ///   - template: Selected task template.
    ///   - discoveredModels: Cached models returned by the selected Mac.
    public init(
        template: MobileTaskTemplate?,
        discoveredModels: [MobileTaskAgentModel]?,
        defaultModel: MobileTaskAgentModel? = nil
    ) {
        provider = template.flatMap {
            MobileTaskAgentProvider(command: $0.command)
        }
        models = discoveredModels ?? []
        self.defaultModel = defaultModel
    }

    /// Validates an identifier against the same list the composer displays.
    ///
    /// A previously validated selection remains accepted if a later refresh
    /// removes it, because the user explicitly selected it while it was offered.
    ///
    /// - Parameters:
    ///   - id: Candidate model identifier.
    ///   - previouslyValidModelID: Earlier validated selection to preserve.
    /// - Returns: The accepted identifier, or `nil`.
    public func validatedModelID(
        _ id: String?,
        previouslyValidModelID: String? = nil
    ) -> String? {
        guard let id else { return nil }
        if models.contains(where: { $0.id == id }) {
            return id
        }
        return id == previouslyValidModelID ? id : nil
    }

    /// Resolves a validated selection for display and submission.
    ///
    /// If a refresh delisted the selected identifier, a raw-name model keeps
    /// the explicit choice visible and valid.
    ///
    /// - Parameter id: A model identifier previously accepted by
    ///   ``validatedModelID(_:previouslyValidModelID:)``.
    /// - Returns: The matching model or a raw-name representation.
    public func selectedModel(id: String?) -> MobileTaskAgentModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
            ?? MobileTaskAgentModel(id: id, displayName: id)
    }
}

/// One coding-agent model returned to the mobile task composer.
public struct MobileTaskModel: Equatable, Sendable {
    /// CLI identifier passed to the provider.
    public let id: String
    /// Product name displayed verbatim by the composer.
    public let displayName: String
    /// Effort values reported for this exact model, in provider order.
    public let efforts: [MobileTaskModelEffort]
    /// Provider-reported default effort, when present in `efforts`.
    public let defaultEffortID: String?

    /// Creates a discovered task model.
    ///
    /// - Parameters:
    ///   - id: CLI identifier passed to the provider.
    ///   - displayName: Product name displayed by the composer.
    public init(
        id: String,
        displayName: String,
        efforts: [MobileTaskModelEffort] = [],
        defaultEffortID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.efforts = efforts
        self.defaultEffortID = efforts.contains { $0.id == defaultEffortID }
            ? defaultEffortID
            : nil
    }
}

/// One effort choice reported for one exact discovered model.
public struct MobileTaskModelEffort: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?

    public init(id: String, displayName: String, description: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}

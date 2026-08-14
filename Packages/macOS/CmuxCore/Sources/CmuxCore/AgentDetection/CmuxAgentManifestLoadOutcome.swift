/// A usable catalog plus an override error that was rejected while loading it.
public struct CmuxAgentManifestLoadOutcome: Equatable, Sendable {
    /// The validated snapshot safe for detection consumers.
    public let snapshot: CmuxAgentManifestSnapshot
    /// The rejected full-catalog error when bundled rules were retained.
    public let rejectedOverrideError: CmuxAgentManifestLoadError?

    /// Creates a load outcome.
    ///
    /// - Parameters:
    ///   - snapshot: The validated snapshot safe to publish.
    ///   - rejectedOverrideError: The rejected override error, if any.
    public init(
        snapshot: CmuxAgentManifestSnapshot,
        rejectedOverrideError: CmuxAgentManifestLoadError? = nil
    ) {
        self.snapshot = snapshot
        self.rejectedOverrideError = rejectedOverrideError
    }
}

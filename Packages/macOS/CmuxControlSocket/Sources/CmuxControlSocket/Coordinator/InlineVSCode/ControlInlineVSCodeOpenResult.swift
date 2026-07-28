/// The app-side result plus the resolved path safe to return on the wire.
public struct ControlInlineVSCodeOpenResult: Sendable, Equatable {
    /// Typed queueing or validation outcome.
    public let resolution: ControlInlineVSCodeOpenResolution
    /// Caller-relative or kernel-canonical path associated with the outcome.
    public let path: String

    /// Creates an inline open result.
    public init(
        resolution: ControlInlineVSCodeOpenResolution,
        path: String
    ) {
        self.resolution = resolution
        self.path = path
    }
}

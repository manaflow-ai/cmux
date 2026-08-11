/// The font configuration values a presentation needs for durable lineage.
///
/// This value exposes no embedded Ghostty handle or runtime ownership.
public struct TerminalFontConfigurationSnapshot: Sendable, Equatable {
    /// The configuration generation that produced the point size.
    public let generation: UInt64

    /// The resolved runtime font size in points.
    public let runtimePoints: Float32

    /// Creates a font configuration snapshot.
    public init(generation: UInt64, runtimePoints: Float32) {
        self.generation = generation
        self.runtimePoints = runtimePoints
    }
}

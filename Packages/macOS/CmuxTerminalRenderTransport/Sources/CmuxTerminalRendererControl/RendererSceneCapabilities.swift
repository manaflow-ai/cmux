/// Semantic-scene features a renderer worker can consume.
public struct RendererSceneCapabilities: OptionSet, Equatable, Sendable {
    /// The raw network bit mask.
    public let rawValue: UInt64

    /// Full semantic scene snapshots.
    public static let fullScene = Self(rawValue: 1 << 0)

    /// Canonical terminal deltas from a preceding scene.
    public static let canonicalDelta = Self(rawValue: 1 << 1)

    /// Presentation-only deltas from a preceding scene.
    public static let presentationDelta = Self(rawValue: 1 << 2)

    /// Every capability defined by this wire version.
    public static let allKnown: Self = [.fullScene, .canonicalDelta, .presentationDelta]

    /// Creates a capability set from its wire mask.
    ///
    /// - Parameter rawValue: The capability mask.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

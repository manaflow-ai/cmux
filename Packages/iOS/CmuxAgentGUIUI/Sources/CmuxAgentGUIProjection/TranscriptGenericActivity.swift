/// Compact fallback presentation for rich entry kinds that are not expanded in this slice.
public struct TranscriptGenericActivity: Hashable, Sendable {
    /// The short kind label shown beside the activity icon.
    public let kindLabel: String
    /// The one-line summary of the activity.
    public let summary: String

    /// Creates a compact generic activity row payload.
    /// - Parameters:
    ///   - kindLabel: The short kind label shown beside the activity icon.
    ///   - summary: The one-line summary of the activity.
    public init(kindLabel: String, summary: String) {
        self.kindLabel = kindLabel
        self.summary = summary
    }
}

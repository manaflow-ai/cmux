import Foundation

/// Backwards-compatible Links snapshot input accepted by the migration seam.
public struct ArtifactLegacyLink: Equatable, Sendable {
    /// Original Links row identity.
    public let id: UUID
    /// URL string captured by the old panel.
    public let url: String
    /// First observation time.
    public let firstSeen: Date
    /// Most recent observation time.
    public let lastSeen: Date
    /// Number of observations.
    public let count: Int
    /// Legacy source label (`osc8` or `detected`).
    public let origin: String
    /// Optional source panel identity.
    public let sourcePanelID: UUID?
    /// Optional source panel title.
    public let sourceSurfaceTitle: String?
    /// Optional fetched page title.
    public let fetchedTitle: String?

    /// Creates a migration input.
    public init(
        id: UUID,
        url: String,
        firstSeen: Date,
        lastSeen: Date,
        count: Int,
        origin: String,
        sourcePanelID: UUID?,
        sourceSurfaceTitle: String?,
        fetchedTitle: String?
    ) {
        self.id = id
        self.url = url
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
        self.origin = origin
        self.sourcePanelID = sourcePanelID
        self.sourceSurfaceTitle = sourceSurfaceTitle
        self.fetchedTitle = fetchedTitle
    }
}

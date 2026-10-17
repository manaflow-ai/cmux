/// One immutable, filtered and sorted provenance group.
public struct ChatArtifactGalleryGroup: Sendable, Equatable, Identifiable {
    /// The group's stable provenance identity.
    public let kind: ChatArtifactGalleryGroupKind
    /// Visible rows in the group's selected ordering.
    public let items: [ChatArtifactGalleryItem]

    /// Stable group identity.
    public var id: ChatArtifactGalleryGroupKind { kind }

    /// Creates a gallery group.
    ///
    /// - Parameters:
    ///   - kind: Stable provenance identity.
    ///   - items: Visible rows in selected order.
    public init(
        kind: ChatArtifactGalleryGroupKind,
        items: [ChatArtifactGalleryItem]
    ) {
        self.kind = kind
        self.items = items
    }
}

public import Foundation

/// Change-detection fingerprint input for one surface in the switcher.
public struct CommandPaletteSwitcherFingerprintSurface: Sendable {
    /// Surface id.
    public let id: UUID
    /// Surface display name.
    public let displayName: String
    /// Surface kind label.
    public let kindLabel: String
    /// Searchable surface metadata.
    public let metadata: CommandPaletteSwitcherSearchMetadata

    /// Creates a surface fingerprint input.
    public init(
        id: UUID,
        displayName: String,
        kindLabel: String,
        metadata: CommandPaletteSwitcherSearchMetadata
    ) {
        self.id = id
        self.displayName = displayName
        self.kindLabel = kindLabel
        self.metadata = metadata
    }
}

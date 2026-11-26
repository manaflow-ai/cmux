public import Foundation

/// Change-detection fingerprint input for one workspace in the switcher.
public struct CommandPaletteSwitcherFingerprintWorkspace: Sendable {
    /// Workspace id.
    public let id: UUID
    /// Workspace display name.
    public let displayName: String
    /// Searchable workspace metadata.
    public let metadata: CommandPaletteSwitcherSearchMetadata
    /// The workspace's surfaces, in switcher order.
    public let surfaces: [CommandPaletteSwitcherFingerprintSurface]

    /// Creates a workspace fingerprint input.
    public init(
        id: UUID,
        displayName: String,
        metadata: CommandPaletteSwitcherSearchMetadata,
        surfaces: [CommandPaletteSwitcherFingerprintSurface]
    ) {
        self.id = id
        self.displayName = displayName
        self.metadata = metadata
        self.surfaces = surfaces
    }
}

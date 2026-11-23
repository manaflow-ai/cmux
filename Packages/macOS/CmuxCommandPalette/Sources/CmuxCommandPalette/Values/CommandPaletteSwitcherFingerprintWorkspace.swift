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
    /// The hex color the workspace's rows are shaded with, if any.
    public let tintColorHex: String?

    /// Creates a workspace fingerprint input.
    public init(
        id: UUID,
        displayName: String,
        metadata: CommandPaletteSwitcherSearchMetadata,
        surfaces: [CommandPaletteSwitcherFingerprintSurface],
        tintColorHex: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.metadata = metadata
        self.surfaces = surfaces
        self.tintColorHex = tintColorHex
    }
}

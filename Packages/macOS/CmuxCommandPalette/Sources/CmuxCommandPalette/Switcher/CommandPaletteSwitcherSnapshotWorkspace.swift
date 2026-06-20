public import Foundation

/// A fully resolved switcher workspace row, produced host-side from live
/// workspace state and consumed by ``CommandPaletteSwitcherEntryBuilder``.
///
/// The host adapter resolves the display name, the localized labels, the
/// searchable metadata, the ordered surfaces, and the activation action; the
/// builder owns the surrounding command structure. See
/// ``CommandPaletteSwitcherSnapshotSurface`` for why this is not `Sendable`.
public struct CommandPaletteSwitcherSnapshotWorkspace {
    /// Workspace id.
    public let id: UUID
    /// Resolved workspace display name.
    public let displayName: String
    /// Localized kind label for the workspace row (resolved app-side).
    public let kindLabel: String
    /// Localized subtitle base for the workspace row (resolved app-side).
    ///
    /// The legacy code uses a distinct localization key from ``kindLabel`` even
    /// though both default to "Workspace"; both keys are preserved by carrying
    /// the two resolved strings separately.
    public let subtitleBase: String
    /// Searchable workspace metadata.
    public let metadata: CommandPaletteSwitcherSearchMetadata
    /// The workspace's surfaces in switcher order. Empty when surfaces are not
    /// included for the current query.
    public let surfaces: [CommandPaletteSwitcherSnapshotSurface]
    /// The action run when the workspace row is activated.
    public let action: () -> Void

    /// Creates a resolved switcher workspace row.
    public init(
        id: UUID,
        displayName: String,
        kindLabel: String,
        subtitleBase: String,
        metadata: CommandPaletteSwitcherSearchMetadata,
        surfaces: [CommandPaletteSwitcherSnapshotSurface],
        action: @escaping () -> Void
    ) {
        self.id = id
        self.displayName = displayName
        self.kindLabel = kindLabel
        self.subtitleBase = subtitleBase
        self.metadata = metadata
        self.surfaces = surfaces
        self.action = action
    }
}

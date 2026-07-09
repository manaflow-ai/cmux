public import Foundation

/// A fully resolved switcher surface row, produced host-side from live panel
/// state and consumed by ``CommandPaletteSwitcherEntryBuilder``.
///
/// The host adapter resolves everything the builder cannot reach across the
/// module boundary: the display name (from the host title helpers), the
/// localized kind label, the searchable metadata, and the activation action.
/// The builder owns the surrounding *structure* (command id, rank, keyword
/// assembly, dismiss-on-run) so the byte-identical entry shape lives in one
/// place.
///
/// Not `Sendable`: it carries the `@MainActor`-bound activation closure and is
/// both built and consumed on the main actor, mirroring ``CommandPaletteCommand``.
public struct CommandPaletteSwitcherSnapshotSurface {
    /// Surface (panel) id.
    public let id: UUID
    /// Resolved surface display name.
    public let displayName: String
    /// Localized surface kind label (resolved app-side).
    public let kindLabel: String
    /// The surface's keyword kind, driving its static keyword list.
    public let keywordKind: CommandPaletteSurfaceKeywordKind
    /// Searchable surface metadata.
    public let metadata: CommandPaletteSwitcherSearchMetadata
    /// The action run when the surface row is activated.
    public let action: () -> Void

    /// Creates a resolved switcher surface row.
    public init(
        id: UUID,
        displayName: String,
        kindLabel: String,
        keywordKind: CommandPaletteSurfaceKeywordKind,
        metadata: CommandPaletteSwitcherSearchMetadata,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.displayName = displayName
        self.kindLabel = kindLabel
        self.keywordKind = keywordKind
        self.metadata = metadata
        self.action = action
    }
}

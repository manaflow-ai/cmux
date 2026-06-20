public import Foundation

/// The pre-creation snapshot a new-workspace insertion plans against: the
/// existing workspaces' value-typed identity/pin shape, the selected
/// workspace's id and pin state, and the inherited working-directory / terminal
/// font the creation seeds into the new workspace.
///
/// Lifted one-for-one from the legacy `TabManager.WorkspaceCreationSnapshot`
/// nested struct. Capturing this `Sendable` value up front decouples the
/// insertion-index and placement computation from the live `@Published` tab
/// storage, so a re-entrant create/close/reorder mid-creation cannot crash the
/// arithmetic by reading half-mutated god-object state (the documented arm64
/// Nightly Cmd+N crash class).
public struct WorkspaceCreationSnapshot: Sendable, Equatable {
    /// The existing workspaces in sidebar order at capture time.
    public let tabs: [WorkspaceCreationTabSnapshot]
    /// The selected workspace's id at capture time, if any.
    public let selectedTabId: UUID?
    /// Whether the selected workspace was pinned at capture time.
    public let selectedTabWasPinned: Bool
    /// The working directory the new workspace inherits, if resolved.
    public let preferredWorkingDirectory: String?
    /// The terminal font point size the new workspace inherits, if any.
    public let inheritedTerminalFontPoints: Float?

    /// Creates a snapshot from already-extracted value data.
    public init(
        tabs: [WorkspaceCreationTabSnapshot],
        selectedTabId: UUID?,
        selectedTabWasPinned: Bool,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.selectedTabWasPinned = selectedTabWasPinned
        self.preferredWorkingDirectory = preferredWorkingDirectory
        self.inheritedTerminalFontPoints = inheritedTerminalFontPoints
    }
}

import Foundation

/// Immutable identity for the app state a command-palette registry describes.
///
/// The control layer resolves routing selectors once, then both `palette.list`
/// and `palette.run` use these same IDs. Keeping this value free of live model
/// references lets execution revalidate targets without changing UI selection.
struct CommandPaletteActionTarget: Sendable, Equatable {
    let windowID: UUID
    let workspaceID: UUID?
    let panelID: UUID?
    /// The config catalog version used when this target was enumerated.
    let configSnapshotID: UUID?

    init(
        windowID: UUID,
        workspaceID: UUID?,
        panelID: UUID?,
        configSnapshotID: UUID? = nil
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.configSnapshotID = configSnapshotID
    }
}

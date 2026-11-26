import Foundation

/// A saved workspace layout under a name (Save Layout as Template…): the screens, columns, splits
/// and tabs of a workspace (``WorkspaceBlueprint``), without its processes. New Workspace from
/// Template builds a new workspace from it with new terminals. Kept by `LayoutTemplateRepository`.
nonisolated struct LayoutTemplate: Hashable, Sendable, Codable, Identifiable {
    /// Stable id: a rename keeps it.
    var id: String
    /// The name the palette lists and `--arg template=` takes; unique among templates, ignoring case.
    var name: String
    var blueprint: WorkspaceBlueprint
    var savedAt: Date
}

import Foundation

/// The palette's input mode: the regular command/switcher list, the file
/// picker, one of the two rename phases, or the workspace-description editor.
public enum CommandPaletteMode {
    /// Regular command/switcher list.
    case commands
    /// Go to File is searching files under the focused workspace root.
    case goToFile
    /// Rename editor is open for `target`.
    case renameInput(CommandPaletteRenameTarget)
    /// Rename confirmation for `target` with the user's `proposedName`.
    case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
    /// Workspace-description editor is open for the target workspace.
    case workspaceDescriptionInput(CommandPaletteWorkspaceDescriptionTarget)
}

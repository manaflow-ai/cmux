import Foundation

/// The palette's input mode: the regular command/switcher list, one of the
/// two rename phases, finite action-argument collection, or the
/// workspace-description editor.
public enum CommandPaletteMode {
    /// Regular command/switcher list.
    case commands
    /// Rename editor is open for `target`.
    case renameInput(CommandPaletteRenameTarget)
    /// Rename confirmation for `target` with the user's `proposedName`.
    case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
    /// Finite-choice arguments are being collected for one action.
    case actionArguments(CommandPaletteArgumentCollection)
    /// Workspace-description editor is open for the target workspace.
    case workspaceDescriptionInput(CommandPaletteWorkspaceDescriptionTarget)
}

import Foundation

/// The palette's input mode: the regular command/switcher list, one of the
/// two rename phases, or the workspace-description editor.
public enum CommandPaletteMode {
    /// Regular command/switcher list.
    case commands
    /// Rename editor is open for `target`.
    case renameInput(CommandPaletteRenameTarget)
    /// Rename confirmation for `target` with the user's `proposedName`.
    case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
    /// Workspace-description editor is open for the target workspace.
    case workspaceDescriptionInput(CommandPaletteWorkspaceDescriptionTarget)
}

extension CommandPaletteMode {
    /// Stable short label for this mode, used in the command-palette DEBUG log.
    /// Ignores associated values so the label is constant per case.
    public var debugModeLabel: String {
        switch self {
        case .commands:
            return "commands"
        case .renameInput:
            return "renameInput"
        case .renameConfirm:
            return "renameConfirm"
        case .workspaceDescriptionInput:
            return "workspaceDescriptionInput"
        }
    }
}

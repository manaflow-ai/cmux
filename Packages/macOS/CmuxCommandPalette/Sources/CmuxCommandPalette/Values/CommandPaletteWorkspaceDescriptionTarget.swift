public import Foundation

/// Identifies the workspace whose description the palette edits and carries
/// the description shown when the editor opens.
public struct CommandPaletteWorkspaceDescriptionTarget: Equatable {
    /// The workspace being edited.
    public let workspaceId: UUID
    /// The current (pre-edit) description.
    public let currentDescription: String

    /// Creates a description-edit target.
    public init(workspaceId: UUID, currentDescription: String) {
        self.workspaceId = workspaceId
        self.currentDescription = currentDescription
    }

    // Strings resolve against the app bundle (`bundle: .main`) so the keys in
    // the app's Localizable.xcstrings (including Japanese) keep working from
    // package code.

    /// Localized input placeholder.
    public var placeholder: String {
        String(
            localized: "commandPalette.description.workspacePlaceholder",
            defaultValue: "Workspace description",
            bundle: .main
        )
    }

    /// Localized input hint shown under the editor.
    public var inputHint: String {
        String(
            localized: "commandPalette.description.workspaceInputHint",
            defaultValue: "Press Enter to save. Press Shift-Enter for a new line, or Escape to cancel.",
            bundle: .main
        )
    }
}

public import Foundation

/// Identifies what a palette rename flow edits (a workspace or a tab) and
/// carries the name shown when the editor opens.
public struct CommandPaletteRenameTarget: Equatable {
    /// The renameable entity.
    public enum Kind: Equatable {
        /// Rename the workspace with this id.
        case workspace(workspaceId: UUID)
        /// Rename the tab `panelId` inside workspace `workspaceId`.
        case tab(workspaceId: UUID, panelId: UUID)
        /// Rename the workspace group with this id. Reached when the focused
        /// workspace is a group's anchor: that row renders the group name, so
        /// the group is what the user is asking to rename.
        case workspaceGroup(groupId: UUID)
    }

    /// The entity being renamed.
    public let kind: Kind
    /// The current (pre-edit) name.
    public let currentName: String

    /// Creates a rename target.
    public init(kind: Kind, currentName: String) {
        self.kind = kind
        self.currentName = currentName
    }

    // Strings resolve against the app bundle (`bundle: .main`) so the keys in
    // the app's Localizable.xcstrings (including Japanese) keep working from
    // package code.

    /// Localized editor title.
    public var title: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceTitle", defaultValue: "Rename Workspace", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabTitle", defaultValue: "Rename Tab", bundle: .main)
        case .workspaceGroup:
            return String(localized: "workspaceGroup.rename.title", defaultValue: "Rename Group", bundle: .main)
        }
    }

    /// Localized editor description.
    public var description: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceDescription", defaultValue: "Choose a custom workspace name.", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabDescription", defaultValue: "Choose a custom tab name.", bundle: .main)
        case .workspaceGroup:
            return String(localized: "workspaceGroup.rename.message", defaultValue: "Enter a new name for this group.", bundle: .main)
        }
    }

    /// Localized input placeholder.
    public var placeholder: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspacePlaceholder", defaultValue: "Workspace name", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabPlaceholder", defaultValue: "Tab name", bundle: .main)
        case .workspaceGroup:
            return String(localized: "workspaceGroup.rename.placeholder", defaultValue: "Group name", bundle: .main)
        }
    }
}

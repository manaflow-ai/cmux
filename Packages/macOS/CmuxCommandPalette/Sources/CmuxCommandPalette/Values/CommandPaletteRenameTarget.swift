public import Foundation

/// Identifies what a palette rename flow edits and carries the name shown when
/// the editor opens.
public struct CommandPaletteRenameTarget: Equatable {
    /// The renameable entity.
    public enum Kind: Equatable {
        /// Rename the workspace with this id.
        case workspace(workspaceId: UUID)
        /// Rename the workspace group with this id.
        case workspaceGroup(groupId: UUID)
        /// Rename the tab `panelId` inside workspace `workspaceId`.
        case tab(workspaceId: UUID, panelId: UUID)
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
        case .workspaceGroup:
            return String(localized: "workspaceGroup.rename.title", defaultValue: "Rename Group", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabTitle", defaultValue: "Rename Tab", bundle: .main)
        }
    }

    /// Localized editor description.
    public var description: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceDescription", defaultValue: "Choose a custom workspace name.", bundle: .main)
        case .workspaceGroup:
            return String(localized: "workspaceGroup.rename.message", defaultValue: "Enter a new name for this group.", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabDescription", defaultValue: "Choose a custom tab name.", bundle: .main)
        }
    }

    /// Localized input placeholder.
    public var placeholder: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspacePlaceholder", defaultValue: "Workspace name", bundle: .main)
        case .workspaceGroup:
            return String(localized: "workspaceGroup.rename.placeholder", defaultValue: "Group name", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabPlaceholder", defaultValue: "Tab name", bundle: .main)
        }
    }

    /// Localized input hint.
    public var inputHint: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceInputHint", defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel.", bundle: .main)
        case .workspaceGroup:
            return String(localized: "commandPalette.rename.workspaceGroupInputHint", defaultValue: "Enter a workspace group name. Press Enter to rename, Escape to cancel.", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabInputHint", defaultValue: "Enter a tab name. Press Enter to rename, Escape to cancel.", bundle: .main)
        }
    }

    /// Localized confirmation hint.
    public var confirmHint: String {
        switch kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.", bundle: .main)
        case .workspaceGroup:
            return String(localized: "commandPalette.rename.workspaceGroupConfirmHint", defaultValue: "Press Enter to apply this workspace group name, or Escape to cancel.", bundle: .main)
        case .tab:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to apply this tab name, or Escape to cancel.", bundle: .main)
        }
    }

    /// Whether submitting an empty name is a valid rename action.
    public var allowsEmptyName: Bool {
        switch kind {
        case .workspace, .tab:
            return true
        case .workspaceGroup:
            return false
        }
    }

    /// Label shown if a confirmation state displays an empty proposed name.
    public var emptyNameConfirmationLabel: String {
        allowsEmptyName
            ? String(localized: "commandPalette.rename.clearCustomName", defaultValue: "(clear custom name)", bundle: .main)
            : currentName
    }
}

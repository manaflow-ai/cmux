import Foundation

/// Controls how the Go to Workspace switcher orders workspaces.
public enum WorkspaceSwitcherOrder: String, CaseIterable, Sendable, SettingCodable {
    /// Preserve the sidebar order, with the selected workspace first.
    case sidebar
    /// Order workspaces by their most recent focus.
    case recent
}

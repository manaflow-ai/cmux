import Foundation

/// Built-in hover controls that cmux can show on a sidebar workspace row.
///
/// Stored under ``SidebarCatalogSection/workspaceControls`` as raw strings in
/// `sidebar.workspaceControls`. The close control is always included so users
/// cannot strand themselves without the existing hover close affordance.
public enum WorkspaceRowControlOption: String, CaseIterable, Sendable, SettingCodable {
    /// Close the workspace.
    case close
    /// Open the workspace-scoped task list.
    case tasks

    /// Maximum number of built-in controls a workspace row may expose.
    public static let maximumVisibleControls = 3

    /// Controls shown when no preference is stored.
    public static let defaultControls: [WorkspaceRowControlOption] = [.close]
}

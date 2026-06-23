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

    /// Returns a duplicate-free, capped list that always includes ``close``.
    ///
    /// Unknown raw values are dropped by callers before reaching this method.
    /// The user's order is otherwise preserved, with ``close`` inserted first
    /// only when it was absent.
    public static func sanitized(_ controls: [WorkspaceRowControlOption]) -> [WorkspaceRowControlOption] {
        var output: [WorkspaceRowControlOption] = []
        var seen = Set<WorkspaceRowControlOption>()

        func append(_ option: WorkspaceRowControlOption) {
            guard output.count < maximumVisibleControls, seen.insert(option).inserted else { return }
            output.append(option)
        }

        if !controls.contains(.close) {
            append(.close)
        }
        for option in controls {
            append(option)
        }
        if output.isEmpty {
            return defaultControls
        }
        return output
    }

    /// Decodes a raw string array from `cmux.json` / `UserDefaults`, dropping
    /// unknown entries before applying the close-control invariant and cap.
    public static func sanitizedRawValues(_ rawValues: [String]) -> [WorkspaceRowControlOption] {
        sanitized(rawValues.compactMap { WorkspaceRowControlOption(rawValue: $0) })
    }
}

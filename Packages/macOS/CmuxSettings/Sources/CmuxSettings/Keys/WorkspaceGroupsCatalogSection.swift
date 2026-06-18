import Foundation

/// Settings under the dotted-id prefix `workspaceGroups.*` — sidebar
/// workspace-group behavior.
public struct WorkspaceGroupsCatalogSection: SettingCatalogSection {
    /// "Don't ask again" suppression flag for the anchor-close confirm
    /// dialog. Defaults to `false` (dialog is shown). The legacy writer
    /// removed the stored object instead of writing `false`; preserve that
    /// by resetting the key when re-enabling the dialog.
    public let anchorCloseSuppressed = DefaultsKey<Bool>(
        id: "workspaceGroups.anchorCloseSuppressed",
        defaultValue: false,
        userDefaultsKey: "workspaceGroup.anchorCloseSuppressed"
    )

    /// Global default for the per-group `+` placement. Used when neither the
    /// per-cwd `cmux.json` entry nor an explicit call-site override pins a
    /// placement. The legacy writer removed the stored object when setting
    /// the default value; preserve that by resetting the key instead of
    /// writing `.afterCurrent`.
    public let newWorkspacePlacement = DefaultsKey<WorkspaceGroupNewPlacement>(
        id: "workspaceGroups.newWorkspacePlacement",
        defaultValue: .afterCurrent,
        userDefaultsKey: "workspaceGroup.newWorkspacePlacement"
    )

    public init() {}
}

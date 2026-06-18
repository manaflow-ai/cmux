import Foundation

/// Settings under the dotted-id prefix `fileExplorer.*`.
public struct FileExplorerCatalogSection: SettingCatalogSection {
    /// What activating a file in the right-sidebar file explorer does.
    public let doubleClickAction = DefaultsKey<FileExplorerDoubleClickAction>(
        id: "fileExplorer.doubleClickAction",
        defaultValue: .preview,
        userDefaultsKey: "fileExplorerDoubleClickAction"
    )

    /// Creates the file explorer settings section with its default keys.
    public init() {}
}

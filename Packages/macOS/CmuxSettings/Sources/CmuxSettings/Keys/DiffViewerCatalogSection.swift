import Foundation

/// Settings under the dotted-id prefix `diffViewer.*`.
public struct DiffViewerCatalogSection: SettingCatalogSection {
    /// Default layout for newly opened diff viewers.
    public let defaultLayout = JSONKey<DiffViewerLayout>(
        id: "diffViewer.defaultLayout",
        defaultValue: .unified
    )

    /// Creates the diff viewer settings section with its default keys.
    public init() {}
}

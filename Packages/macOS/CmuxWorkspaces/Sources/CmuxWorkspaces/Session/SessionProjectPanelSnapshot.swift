/// Persisted state for a project surface inside a session snapshot.
///
/// A pure leaf value carrying the project root path plus the selected node,
/// active tab, and selected scheme/configuration restored on reopen. The
/// on-disk wire format is owned by the app's session snapshot; encoding stays
/// byte-identical to the legacy app-target definition (default `Codable`
/// synthesis over the same stored-property set).
public struct SessionProjectPanelSnapshot: Codable, Sendable {
    /// The project root path.
    public var projectPath: String
    /// The selected file-tree node's path, when one is selected.
    public var selectedNodePath: String?
    /// The active project tab identifier, when one is active.
    public var activeTab: String?
    /// The selected build scheme name, when one is chosen.
    public var selectedSchemeName: String?
    /// The selected build configuration name, when one is chosen.
    public var selectedConfigurationName: String?

    /// Creates a project panel snapshot from explicit components.
    public init(
        projectPath: String,
        selectedNodePath: String? = nil,
        activeTab: String? = nil,
        selectedSchemeName: String? = nil,
        selectedConfigurationName: String? = nil
    ) {
        self.projectPath = projectPath
        self.selectedNodePath = selectedNodePath
        self.activeTab = activeTab
        self.selectedSchemeName = selectedSchemeName
        self.selectedConfigurationName = selectedConfigurationName
    }
}

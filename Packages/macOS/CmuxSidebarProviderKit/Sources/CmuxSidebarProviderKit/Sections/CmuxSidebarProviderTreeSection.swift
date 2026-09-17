import Foundation

/// Tree section metadata used by CMUX's built-in sidebar layout.
public struct CmuxSidebarProviderTreeSection: Identifiable, Codable, Equatable, Sendable {
    /// Stable section id.
    public var id: String
    /// Plain section title fallback.
    public var title: String
    /// Optional localized section title.
    public var titleText: CmuxSidebarProviderLocalizedText?
    /// Plain subtitle fallback.
    public var subtitle: String?
    /// Optional localized subtitle.
    public var subtitleText: CmuxSidebarProviderLocalizedText?
    /// SF Symbols name for the section icon.
    public var systemImageName: String
    /// Project root represented by this section, if any.
    public var projectRootPath: String?
    /// Workspace ids included in this tree section.
    public var workspaceIds: [UUID]

    /// Creates tree section metadata.
    public init(
        id: String,
        title: String,
        titleText: CmuxSidebarProviderLocalizedText? = nil,
        subtitle: String?,
        subtitleText: CmuxSidebarProviderLocalizedText? = nil,
        systemImageName: String,
        projectRootPath: String?,
        workspaceIds: [UUID]
    ) {
        self.id = id
        self.title = title
        self.titleText = titleText
        self.subtitle = subtitle
        self.subtitleText = subtitleText
        self.systemImageName = systemImageName
        self.projectRootPath = projectRootPath
        self.workspaceIds = workspaceIds
    }
}

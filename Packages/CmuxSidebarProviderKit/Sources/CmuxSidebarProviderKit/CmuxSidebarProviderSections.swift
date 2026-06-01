import Foundation

public struct CmuxSidebarProviderTreeSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var titleText: CmuxSidebarProviderLocalizedText?
    public var subtitle: String?
    public var subtitleText: CmuxSidebarProviderLocalizedText?
    public var systemImageName: String
    public var projectRootPath: String?
    public var workspaceIds: [UUID]

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

public struct CmuxSidebarProviderSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var treeSection: CmuxSidebarProviderTreeSection
    public var rows: [CmuxSidebarProviderRow]

    public init(
        id: String,
        treeSection: CmuxSidebarProviderTreeSection,
        rows: [CmuxSidebarProviderRow]
    ) {
        self.id = id
        self.treeSection = treeSection
        self.rows = rows
    }
}

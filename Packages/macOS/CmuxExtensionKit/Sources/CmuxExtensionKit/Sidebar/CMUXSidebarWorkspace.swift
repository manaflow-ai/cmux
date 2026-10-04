import Foundation

public struct CmuxSidebarWorkspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var isPinned: Bool
    public var rootPath: String?
    public var projectRootPath: String?
    public var gitBranch: String?
    public var unreadCount: Int
    public var latestNotification: String?
    public var listeningPorts: [Int]
    public var pullRequestURLs: [String]
    public var surfaces: [CmuxSidebarSurface]
    /// Native group assignment, shared only with the workspace-groups scope.
    public var groupID: UUID?
    /// User-selected importance, independent of pinning and runtime activity.
    public var importance: CmuxSidebarWorkspaceImportance
    /// Whether this workspace's notifications are muted.
    public var isMuted: Bool
    /// Native custom color in hexadecimal form, or `nil` for the default color.
    public var customColorHex: String?

    public init(
        id: UUID,
        title: String,
        detail: String? = nil,
        isPinned: Bool = false,
        rootPath: String? = nil,
        projectRootPath: String? = nil,
        gitBranch: String? = nil,
        unreadCount: Int = 0,
        latestNotification: String? = nil,
        listeningPorts: [Int] = [],
        pullRequestURLs: [String] = [],
        surfaces: [CmuxSidebarSurface] = [],
        groupID: UUID? = nil,
        importance: CmuxSidebarWorkspaceImportance = .none,
        isMuted: Bool = false,
        customColorHex: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isPinned = isPinned
        self.rootPath = rootPath
        self.projectRootPath = projectRootPath
        self.gitBranch = gitBranch
        self.unreadCount = unreadCount
        self.latestNotification = latestNotification
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
        self.surfaces = surfaces
        self.groupID = groupID
        self.importance = importance
        self.isMuted = isMuted
        self.customColorHex = customColorHex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        projectRootPath = try container.decodeIfPresent(String.self, forKey: .projectRootPath)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        unreadCount = try container.decode(Int.self, forKey: .unreadCount)
        latestNotification = try container.decodeIfPresent(String.self, forKey: .latestNotification)
        listeningPorts = try container.decode([Int].self, forKey: .listeningPorts)
        pullRequestURLs = try container.decode([String].self, forKey: .pullRequestURLs)
        surfaces = try container.decodeIfPresent([CmuxSidebarSurface].self, forKey: .surfaces) ?? []
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        importance = try container.decodeIfPresent(CmuxSidebarWorkspaceImportance.self, forKey: .importance) ?? .none
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        customColorHex = try container.decodeIfPresent(String.self, forKey: .customColorHex)
    }

    @_spi(CmuxHostTransport)
    public func filtered(for scopes: some Sequence<CmuxExtensionScope>) -> CmuxSidebarWorkspace {
        let scopeSet = Set(scopes)
        return CmuxSidebarWorkspace(
            id: id,
            title: title,
            detail: detail,
            isPinned: isPinned,
            rootPath: scopeSet.contains(.workspacePaths) ? rootPath : nil,
            projectRootPath: scopeSet.contains(.workspacePaths) ? projectRootPath : nil,
            gitBranch: gitBranch,
            unreadCount: unreadCount,
            latestNotification: scopeSet.contains(.notifications) ? latestNotification : nil,
            listeningPorts: scopeSet.contains(.networkPorts) ? listeningPorts : [],
            pullRequestURLs: scopeSet.contains(.pullRequests) ? pullRequestURLs : [],
            surfaces: scopeSet.contains(.surfaceMetadata) ? surfaces.map { $0.filtered(for: scopeSet) } : [],
            groupID: scopeSet.contains(.workspaceGroups) ? groupID : nil,
            importance: importance,
            isMuted: isMuted,
            customColorHex: customColorHex
        )
    }
}

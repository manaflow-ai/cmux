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
        surfaces: [CmuxSidebarSurface] = []
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
            surfaces: scopeSet.contains(.surfaceMetadata) ? surfaces.map { $0.filtered(for: scopeSet) } : []
        )
    }
}

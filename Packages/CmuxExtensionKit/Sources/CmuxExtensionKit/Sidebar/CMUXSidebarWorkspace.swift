import Foundation

public struct CMUXSidebarWorkspace: Codable, Equatable, Identifiable, Sendable {
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
        pullRequestURLs: [String] = []
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
    }
}

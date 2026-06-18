import Foundation
import CmuxExtensionKit

struct SidebarInsightModel {
    var sequence: UInt64
    var totalCount: Int
    var pinnedCount: Int
    var unreadCount: Int
    var portCount: Int
    var pullRequestCount: Int
    var canSelectWorkspace: Bool
    var canCreateSurface: Bool
    var canNavigateWorkspace: Bool
    var canNavigateSurface: Bool
    var hasWorkspaceMetadata: Bool
    var selectedWorkspace: WorkspaceInsight?
    var allWorkspaces: [WorkspaceInsight]
    var focusQueue: [WorkspaceInsight]

    init(snapshot: CmuxSidebarSnapshot) {
        let insights = snapshot.workspaces.map {
            WorkspaceInsight(workspace: $0, selectedWorkspaceID: snapshot.selectedWorkspaceID)
        }
        sequence = snapshot.sequence
        totalCount = insights.count
        pinnedCount = insights.filter(\.isPinned).count
        unreadCount = insights.reduce(0) { $0 + $1.unreadCount }
        portCount = insights.reduce(0) { $0 + $1.portCount }
        pullRequestCount = insights.reduce(0) { $0 + $1.pullRequestCount }
        canSelectWorkspace = snapshot.grantedActionScopes.contains(.selectWorkspace)
        canCreateSurface = snapshot.grantedActionScopes.contains(.createSurface)
        canNavigateWorkspace = snapshot.grantedActionScopes.contains(.navigateWorkspace)
        canNavigateSurface = snapshot.grantedActionScopes.contains(.navigateSurface)
        hasWorkspaceMetadata = snapshot.grantedReadScopes.contains(.workspaceMetadata)
        selectedWorkspace = insights.first(where: \.isSelected)
        allWorkspaces = insights
        focusQueue = insights
            .filter { $0.hasSignal && !$0.isSelected }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}

struct WorkspaceInsight: Identifiable {
    var id: UUID
    var title: String
    var subtitle: String
    var isSelected: Bool
    var isPinned: Bool
    var unreadCount: Int
    var portCount: Int
    var pullRequestCount: Int
    var branch: String?
    var latestNotification: String?
    var surfaces: [SurfaceInsight]

    init(workspace: CmuxSidebarWorkspace, selectedWorkspaceID: UUID?) {
        id = workspace.id
        title = workspace.title
        subtitle = workspace.detail ?? workspace.rootPath?.lastPathComponent ?? workspace.projectRootPath?.lastPathComponent ?? ""
        isSelected = workspace.id == selectedWorkspaceID
        isPinned = workspace.isPinned
        unreadCount = max(0, workspace.unreadCount)
        portCount = workspace.listeningPorts.count
        pullRequestCount = workspace.pullRequestURLs.count
        branch = workspace.gitBranch
        latestNotification = workspace.latestNotification
        surfaces = workspace.surfaces.map(SurfaceInsight.init(surface:))
    }

    var hasSignal: Bool {
        isSelected || isPinned || unreadCount > 0 || portCount > 0 || pullRequestCount > 0 || latestNotification != nil
    }

    var score: Int {
        (isSelected ? 1000 : 0)
            + (unreadCount * 100)
            + (portCount * 20)
            + (pullRequestCount * 10)
            + (isPinned ? 5 : 0)
    }
}

struct SurfaceInsight: Identifiable {
    var id: UUID
    var title: String
    var kind: CmuxSidebarSurfaceKind
    var isFocused: Bool
    var unreadCount: Int

    init(surface: CmuxSidebarSurface) {
        id = surface.id
        title = surface.title
        kind = surface.kind
        isFocused = surface.isFocused
        unreadCount = max(0, surface.unreadCount)
    }

    var iconName: String {
        switch kind {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .filePreview:
            return "doc"
        case .rightSidebarTool:
            return "sidebar.right"
        case .project:
            return "folder"
        case .unknown:
            return "rectangle"
        }
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

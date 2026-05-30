import Foundation

public enum CmuxExtensionSidebarPresentation: String, Codable, Equatable, Sendable {
    case tree
    case browserStack = "browser-stack"
}

public struct CmuxExtensionWorkspaceTreeSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var titleText: CmuxExtensionLocalizedText?
    public var subtitle: String?
    public var subtitleText: CmuxExtensionLocalizedText?
    public var systemImageName: String
    public var projectRootPath: String?
    public var workspaceIds: [UUID]

    public init(
        id: String,
        title: String,
        titleText: CmuxExtensionLocalizedText? = nil,
        subtitle: String?,
        subtitleText: CmuxExtensionLocalizedText? = nil,
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

public enum CmuxExtensionWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    case notes
    case browser
    case pullRequest
}

public enum CmuxExtensionWorkspaceRowAccessoryKind: String, Codable, Equatable, Sendable {
    case workspaceInspector
}

public struct CmuxExtensionWorkspaceRowAccessory: Codable, Equatable, Sendable {
    public var kind: CmuxExtensionWorkspaceRowAccessoryKind
    public var systemImageName: String
    public var defaultTab: CmuxExtensionWorkspacePopoverTab

    public init(
        kind: CmuxExtensionWorkspaceRowAccessoryKind,
        systemImageName: String,
        defaultTab: CmuxExtensionWorkspacePopoverTab
    ) {
        self.kind = kind
        self.systemImageName = systemImageName
        self.defaultTab = defaultTab
    }

    public static let inspector = CmuxExtensionWorkspaceRowAccessory(
        kind: .workspaceInspector,
        systemImageName: "ellipsis.circle",
        defaultTab: .notes
    )
}

public enum CmuxExtensionSidebarRelativeDateStyle: String, Codable, Equatable, Sendable {
    case compact
}

public enum CmuxExtensionSidebarRenderIconShape: String, Codable, Equatable, Sendable {
    case circle
    case roundedRectangle = "rounded-rectangle"
}

public struct CmuxExtensionSidebarRenderIcon: Codable, Equatable, Sendable {
    public var systemImageName: String?
    public var text: String?
    public var foregroundColorHex: String?
    public var backgroundColorHex: String?
    public var shape: CmuxExtensionSidebarRenderIconShape

    public init(
        systemImageName: String? = nil,
        text: String? = nil,
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        shape: CmuxExtensionSidebarRenderIconShape = .circle
    ) {
        self.systemImageName = systemImageName
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.shape = shape
    }
}

public enum CmuxExtensionSidebarRenderText: Codable, Equatable, Sendable {
    case plain(String)
    case localized(CmuxExtensionLocalizedText)
    case relativeDate(Date, style: CmuxExtensionSidebarRelativeDateStyle)

    public var relativeDate: Date? {
        switch self {
        case .plain, .localized:
            return nil
        case .relativeDate(let date, _):
            return date
        }
    }
}

public struct CmuxExtensionSidebarRenderRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var workspaceId: UUID
    public var accessory: CmuxExtensionWorkspaceRowAccessory?
    public var subtitle: CmuxExtensionSidebarRenderText?
    public var trailingText: CmuxExtensionSidebarRenderText?
    public var leadingIcon: CmuxExtensionSidebarRenderIcon?

    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: CmuxExtensionWorkspaceRowAccessory?,
        subtitle: CmuxExtensionSidebarRenderText? = nil,
        trailingText: CmuxExtensionSidebarRenderText? = nil,
        leadingIcon: CmuxExtensionSidebarRenderIcon? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.accessory = accessory
        self.subtitle = subtitle
        self.trailingText = trailingText
        self.leadingIcon = leadingIcon
    }
}

public struct CmuxExtensionSidebarRenderSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var treeSection: CmuxExtensionWorkspaceTreeSection
    public var rows: [CmuxExtensionSidebarRenderRow]

    public init(
        id: String,
        treeSection: CmuxExtensionWorkspaceTreeSection,
        rows: [CmuxExtensionSidebarRenderRow]
    ) {
        self.id = id
        self.treeSection = treeSection
        self.rows = rows
    }
}

public struct CmuxExtensionSidebarRenderModel: Codable, Equatable, Sendable {
    public var providerId: String
    public var snapshotSequence: UInt64
    public var sections: [CmuxExtensionSidebarRenderSection]
    public var presentation: CmuxExtensionSidebarPresentation

    public init(
        providerId: String,
        snapshotSequence: UInt64,
        sections: [CmuxExtensionSidebarRenderSection],
        presentation: CmuxExtensionSidebarPresentation = .tree
    ) {
        self.providerId = providerId
        self.snapshotSequence = snapshotSequence
        self.sections = sections
        self.presentation = presentation
    }
}

public enum CmuxExtensionSidebarPresentationRequest: Codable, Equatable, Sendable {
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxExtensionWorkspacePopoverTab)
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxExtensionWorkspacePopoverTab)
    case openURL(String)
}

public struct CmuxExtensionSidebarWorkspaceMove: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var sourceSectionId: String?
    public var targetSectionId: String
    public var targetIndex: Int

    public init(
        workspaceId: UUID,
        sourceSectionId: String?,
        targetSectionId: String,
        targetIndex: Int
    ) {
        self.workspaceId = workspaceId
        self.sourceSectionId = sourceSectionId
        self.targetSectionId = targetSectionId
        self.targetIndex = targetIndex
    }
}

public enum CmuxExtensionSidebarMutation: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case createWorktree(projectRootPath: String)
    case moveWorkspace(CmuxExtensionSidebarWorkspaceMove)
    case present(CmuxExtensionSidebarPresentationRequest)
}

public struct CmuxExtensionCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct CmuxExtensionSidebarRenderContext: Codable, Equatable, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }
}

public protocol CmuxExtensionSidebarContextualProvider: CmuxExtensionSidebarProvider {
    func render(snapshot: CmuxExtensionSidebarSnapshot, context: CmuxExtensionSidebarRenderContext) -> CmuxExtensionSidebarRenderModel
}

public protocol CmuxExtensionSidebarMutableProvider: CmuxExtensionSidebarContextualProvider {
    func handle(
        _ mutation: CmuxExtensionSidebarMutation,
        snapshot: CmuxExtensionSidebarSnapshot
    ) throws -> CmuxExtensionCommandResult
}

public extension CmuxExtensionSidebarProvider {
    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    func render(
        snapshot: CmuxExtensionSidebarSnapshot,
        context: CmuxExtensionSidebarRenderContext
    ) -> CmuxExtensionSidebarRenderModel {
        render(snapshot: snapshot)
    }
}

public struct CmuxExtensionSidebarSnapshot: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var selectedWorkspaceId: UUID?
    public var workspaces: [CmuxExtensionWorkspaceSnapshot]
    public var windowId: UUID?

    public init(
        sequence: UInt64,
        selectedWorkspaceId: UUID?,
        workspaces: [CmuxExtensionWorkspaceSnapshot],
        windowId: UUID? = nil
    ) {
        self.sequence = sequence
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
        self.windowId = windowId
    }

    public var workspaceIds: [UUID] {
        workspaces.map(\.id)
    }
}

public struct CmuxExtensionGitBranchSnapshot: Codable, Equatable, Sendable {
    public var branch: String
    public var isDirty: Bool

    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}

public struct CmuxExtensionWorkspaceSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var customDescription: String?
    public var isPinned: Bool
    public var rootPath: String?
    public var projectRootPath: String?
    public var branchSummary: String?
    public var remoteDisplayTarget: String?
    public var remoteConnectionState: String?
    public var unreadCount: Int
    public var latestNotificationText: String?
    public var latestSubmittedMessage: String?
    public var latestSubmittedAt: Date?
    public var listeningPorts: [Int]
    public var pullRequestURLs: [String]
    public var panelDirectories: [String]
    public var gitBranches: [CmuxExtensionGitBranchSnapshot]

    public init(
        id: UUID,
        title: String,
        customDescription: String?,
        isPinned: Bool,
        rootPath: String?,
        projectRootPath: String?,
        branchSummary: String?,
        remoteDisplayTarget: String?,
        remoteConnectionState: String?,
        unreadCount: Int,
        latestNotificationText: String?,
        latestSubmittedMessage: String? = nil,
        latestSubmittedAt: Date? = nil,
        listeningPorts: [Int],
        pullRequestURLs: [String] = [],
        panelDirectories: [String] = [],
        gitBranches: [CmuxExtensionGitBranchSnapshot] = []
    ) {
        self.id = id
        self.title = title
        self.customDescription = customDescription
        self.isPinned = isPinned
        self.rootPath = rootPath
        self.projectRootPath = projectRootPath
        self.branchSummary = branchSummary
        self.remoteDisplayTarget = remoteDisplayTarget
        self.remoteConnectionState = remoteConnectionState
        self.unreadCount = unreadCount
        self.latestNotificationText = latestNotificationText
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAt = latestSubmittedAt
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
        self.panelDirectories = panelDirectories
        self.gitBranches = gitBranches
    }
}

import Foundation

public enum CmuxSidebarProviderPresentation: String, Codable, Equatable, Sendable {
    case tree
    case browserStack = "browser-stack"
}

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

public enum CmuxSidebarProviderWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    case notes
    case browser
    case pullRequest
}

public enum CmuxSidebarProviderRowAccessoryKind: String, Codable, Equatable, Sendable {
    case workspaceInspector
}

public struct CmuxSidebarProviderRowAccessory: Codable, Equatable, Sendable {
    public var kind: CmuxSidebarProviderRowAccessoryKind
    public var systemImageName: String
    public var defaultTab: CmuxSidebarProviderWorkspacePopoverTab

    public init(
        kind: CmuxSidebarProviderRowAccessoryKind,
        systemImageName: String,
        defaultTab: CmuxSidebarProviderWorkspacePopoverTab
    ) {
        self.kind = kind
        self.systemImageName = systemImageName
        self.defaultTab = defaultTab
    }

    public static let inspector = CmuxSidebarProviderRowAccessory(
        kind: .workspaceInspector,
        systemImageName: "ellipsis.circle",
        defaultTab: .notes
    )
}

public enum CmuxSidebarProviderRelativeDateStyle: String, Codable, Equatable, Sendable {
    case compact
}

public enum CmuxSidebarProviderIconShape: String, Codable, Equatable, Sendable {
    case circle
    case roundedRectangle = "rounded-rectangle"
}

public struct CmuxSidebarProviderIcon: Codable, Equatable, Sendable {
    public var systemImageName: String?
    public var text: String?
    public var foregroundColorHex: String?
    public var backgroundColorHex: String?
    public var shape: CmuxSidebarProviderIconShape

    public init(
        systemImageName: String? = nil,
        text: String? = nil,
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        shape: CmuxSidebarProviderIconShape = .circle
    ) {
        self.systemImageName = systemImageName
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.shape = shape
    }
}

public enum CmuxSidebarProviderText: Codable, Equatable, Sendable {
    case plain(String)
    case localized(CmuxSidebarProviderLocalizedText)
    case relativeDate(Date, style: CmuxSidebarProviderRelativeDateStyle)

    public var relativeDate: Date? {
        switch self {
        case .plain, .localized:
            return nil
        case .relativeDate(let date, _):
            return date
        }
    }
}

public struct CmuxSidebarProviderRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var workspaceId: UUID
    public var accessory: CmuxSidebarProviderRowAccessory?
    public var subtitle: CmuxSidebarProviderText?
    public var trailingText: CmuxSidebarProviderText?
    public var leadingIcon: CmuxSidebarProviderIcon?

    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: CmuxSidebarProviderRowAccessory?,
        subtitle: CmuxSidebarProviderText? = nil,
        trailingText: CmuxSidebarProviderText? = nil,
        leadingIcon: CmuxSidebarProviderIcon? = nil
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

public struct CmuxSidebarProviderRenderModel: Codable, Equatable, Sendable {
    public var providerId: String
    public var snapshotSequence: UInt64
    public var sections: [CmuxSidebarProviderSection]
    public var presentation: CmuxSidebarProviderPresentation

    public init(
        providerId: String,
        snapshotSequence: UInt64,
        sections: [CmuxSidebarProviderSection],
        presentation: CmuxSidebarProviderPresentation = .tree
    ) {
        self.providerId = providerId
        self.snapshotSequence = snapshotSequence
        self.sections = sections
        self.presentation = presentation
    }
}

public enum CmuxSidebarProviderPresentationRequest: Codable, Equatable, Sendable {
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxSidebarProviderWorkspacePopoverTab)
    case openURL(String)
}

public struct CmuxSidebarProviderWorkspaceMove: Codable, Equatable, Sendable {
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

public enum CmuxSidebarProviderMutation: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case createWorktree(projectRootPath: String)
    case moveWorkspace(CmuxSidebarProviderWorkspaceMove)
    case present(CmuxSidebarProviderPresentationRequest)
}

public struct CmuxSidebarProviderCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct CmuxSidebarProviderRenderContext: Codable, Equatable, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }
}

public protocol CmuxContextualSidebarProvider: CmuxSidebarProvider {
    func render(snapshot: CmuxSidebarProviderSnapshot, context: CmuxSidebarProviderRenderContext) -> CmuxSidebarProviderRenderModel
}

public protocol CmuxMutableSidebarProvider: CmuxContextualSidebarProvider {
    func handle(
        _ mutation: CmuxSidebarProviderMutation,
        snapshot: CmuxSidebarProviderSnapshot
    ) throws -> CmuxSidebarProviderCommandResult
}

public extension CmuxSidebarProvider {
    func render(snapshot: CmuxSidebarProviderSnapshot) -> CmuxSidebarProviderRenderModel {
        CmuxSidebarProviderRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    func render(
        snapshot: CmuxSidebarProviderSnapshot,
        context: CmuxSidebarProviderRenderContext
    ) -> CmuxSidebarProviderRenderModel {
        render(snapshot: snapshot)
    }
}

public struct CmuxSidebarProviderSnapshot: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var selectedWorkspaceId: UUID?
    public var workspaces: [CmuxSidebarProviderWorkspace]
    public var windowId: UUID?

    public init(
        sequence: UInt64,
        selectedWorkspaceId: UUID?,
        workspaces: [CmuxSidebarProviderWorkspace],
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

public struct CmuxSidebarProviderGitBranch: Codable, Equatable, Sendable {
    public var branch: String
    public var isDirty: Bool

    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}

public struct CmuxSidebarProviderWorkspace: Identifiable, Codable, Equatable, Sendable {
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
    public var gitBranches: [CmuxSidebarProviderGitBranch]

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
        gitBranches: [CmuxSidebarProviderGitBranch] = []
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

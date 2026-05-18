import Foundation

public struct CmuxExtensionLocalizedText: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var defaultValue: String

    public init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

public struct CmuxExtensionSidebarSnapshot: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var selectedWorkspaceId: UUID?
    public var workspaces: [CmuxExtensionWorkspaceSnapshot]

    public init(
        sequence: UInt64,
        selectedWorkspaceId: UUID?,
        workspaces: [CmuxExtensionWorkspaceSnapshot]
    ) {
        self.sequence = sequence
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
    }

    public var workspaceIds: [UUID] {
        workspaces.map(\.id)
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
    public var listeningPorts: [Int]
    public var pullRequestURLs: [String]

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
        listeningPorts: [Int],
        pullRequestURLs: [String] = []
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
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
    }
}

public enum CmuxExtensionSidebarEvent: Codable, Equatable, Sendable {
    case snapshotReplaced(CmuxExtensionSidebarSnapshot)
    case workspaceUpserted(CmuxExtensionWorkspaceSnapshot)
    case workspaceRemoved(UUID)
    case workspacesReordered([UUID])
    case workspaceSelected(UUID?)
}

public struct CmuxExtensionSidebarReducer {
    public static func reduce(
        _ snapshot: CmuxExtensionSidebarSnapshot,
        event: CmuxExtensionSidebarEvent
    ) -> CmuxExtensionSidebarSnapshot {
        switch event {
        case .snapshotReplaced(let replacement):
            return replacement

        case .workspaceUpserted(let workspace):
            var workspaces = snapshot.workspaces
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: snapshot.selectedWorkspaceId,
                workspaces: workspaces
            )

        case .workspaceRemoved(let id):
            let workspaces = snapshot.workspaces.filter { $0.id != id }
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: snapshot.selectedWorkspaceId == id ? nil : snapshot.selectedWorkspaceId,
                workspaces: workspaces
            )

        case .workspacesReordered(let ids):
            let indexById = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            let known = snapshot.workspaces.sorted { lhs, rhs in
                (indexById[lhs.id] ?? Int.max) < (indexById[rhs.id] ?? Int.max)
            }
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: snapshot.selectedWorkspaceId,
                workspaces: known
            )

        case .workspaceSelected(let id):
            return CmuxExtensionSidebarSnapshot(
                sequence: snapshot.sequence + 1,
                selectedWorkspaceId: id,
                workspaces: snapshot.workspaces
            )
        }
    }
}

public enum CmuxExtensionSidebarProviderID {
    public static let defaultWorkspaces = "cmux.sidebar.default"
    public static let projectTree = "cmux.sidebar.project-tree"
    public static let attention = "cmux.sidebar.attention"
    public static let servers = "cmux.sidebar.servers"
}

public enum CmuxExtensionSidebarCustomizationMode: String, Codable, Equatable, Sendable {
    case projectTree = "project-tree"
    case attention
    case servers

    public var allowsProjectWorktreeActions: Bool {
        self == .projectTree
    }
}

public struct CmuxExtensionSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: CmuxExtensionLocalizedText
    public var subtitle: CmuxExtensionLocalizedText?
    public var systemImageName: String
    public var mode: CmuxExtensionSidebarCustomizationMode?
    public var isHostProvided: Bool

    public init(
        id: String,
        title: CmuxExtensionLocalizedText,
        subtitle: CmuxExtensionLocalizedText?,
        systemImageName: String,
        mode: CmuxExtensionSidebarCustomizationMode?,
        isHostProvided: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.mode = mode
        self.isHostProvided = isHostProvided
    }

    public static let defaultWorkspaces = CmuxExtensionSidebarProviderDescriptor(
        id: CmuxExtensionSidebarProviderID.defaultWorkspaces,
        title: CmuxExtensionLocalizedText(
            key: "sidebar.provider.default.title",
            defaultValue: "Default Workspaces"
        ),
        subtitle: CmuxExtensionLocalizedText(
            key: "sidebar.provider.default.subtitle",
            defaultValue: "cmux"
        ),
        systemImageName: "list.bullet",
        mode: nil,
        isHostProvided: true
    )

    public static let projectTree = CmuxExtensionSidebarProviderDescriptor(
        id: CmuxExtensionSidebarProviderID.projectTree,
        title: CmuxExtensionLocalizedText(
            key: "sidebar.provider.projectTree.title",
            defaultValue: "Project Tree"
        ),
        subtitle: CmuxExtensionLocalizedText(
            key: "sidebar.provider.projectTree.subtitle",
            defaultValue: "CmuxExtensionKit"
        ),
        systemImageName: "folder",
        mode: .projectTree,
        isHostProvided: true
    )

    public static let attention = CmuxExtensionSidebarProviderDescriptor(
        id: CmuxExtensionSidebarProviderID.attention,
        title: CmuxExtensionLocalizedText(
            key: "sidebar.provider.attention.title",
            defaultValue: "Attention"
        ),
        subtitle: CmuxExtensionLocalizedText(
            key: "sidebar.provider.attention.subtitle",
            defaultValue: "CmuxExtensionKit"
        ),
        systemImageName: "bell",
        mode: .attention,
        isHostProvided: true
    )

    public static let servers = CmuxExtensionSidebarProviderDescriptor(
        id: CmuxExtensionSidebarProviderID.servers,
        title: CmuxExtensionLocalizedText(
            key: "sidebar.provider.servers.title",
            defaultValue: "Servers"
        ),
        subtitle: CmuxExtensionLocalizedText(
            key: "sidebar.provider.servers.subtitle",
            defaultValue: "CmuxExtensionKit"
        ),
        systemImageName: "terminal",
        mode: .servers,
        isHostProvided: true
    )

    public static let builtInProviders: [CmuxExtensionSidebarProviderDescriptor] = [
        .defaultWorkspaces,
        .projectTree,
        .attention,
        .servers,
    ]
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

public struct CmuxExtensionSidebarRenderRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var workspaceId: UUID
    public var accessory: CmuxExtensionWorkspaceRowAccessory?

    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: CmuxExtensionWorkspaceRowAccessory?
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.accessory = accessory
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

    public init(
        providerId: String,
        snapshotSequence: UInt64,
        sections: [CmuxExtensionSidebarRenderSection]
    ) {
        self.providerId = providerId
        self.snapshotSequence = snapshotSequence
        self.sections = sections
    }
}

public enum CmuxExtensionSidebarPresentationRequest: Codable, Equatable, Sendable {
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxExtensionWorkspacePopoverTab)
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxExtensionWorkspacePopoverTab)
    case openURL(String)
}

public enum CmuxExtensionSidebarMutation: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case createWorktree(projectRootPath: String)
    case present(CmuxExtensionSidebarPresentationRequest)
}

public protocol CmuxExtensionSidebarProvider: Sendable {
    var descriptor: CmuxExtensionSidebarProviderDescriptor { get }

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel
}

public struct CmuxExtensionWorkspaceTreeProvider: CmuxExtensionSidebarProvider {
    public var descriptor: CmuxExtensionSidebarProviderDescriptor

    public init(descriptor: CmuxExtensionSidebarProviderDescriptor) {
        self.descriptor = descriptor
    }

    public func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        render(snapshot: snapshot, localize: { $0.defaultValue })
    }

    public func render(
        snapshot: CmuxExtensionSidebarSnapshot,
        localize: CmuxExtensionWorkspaceTreeBuilder.Localize
    ) -> CmuxExtensionSidebarRenderModel {
        let mode = descriptor.mode ?? .projectTree
        let sections = CmuxExtensionWorkspaceTreeBuilder.sections(for: snapshot, mode: mode, localize: localize)
        let workspacesById = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
        return CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: sections.map { section in
                CmuxExtensionSidebarRenderSection(
                    id: section.id,
                    treeSection: section,
                    rows: section.workspaceIds.compactMap { workspaceId in
                        guard let workspace = workspacesById[workspaceId] else { return nil }
                        return CmuxExtensionSidebarRenderRow(
                            id: workspace.id,
                            title: workspace.title,
                            workspaceId: workspace.id,
                            accessory: .inspector
                        )
                    }
                )
            }
        )
    }
}

public enum CmuxExtensionWorkspaceTreeBuilder {
    public typealias Localize = @Sendable (CmuxExtensionLocalizedText) -> String

    public static func sections(
        for snapshot: CmuxExtensionSidebarSnapshot,
        mode: CmuxExtensionSidebarCustomizationMode,
        localize: Localize = { $0.defaultValue }
    ) -> [CmuxExtensionWorkspaceTreeSection] {
        switch mode {
        case .projectTree:
            return projectTreeSections(for: snapshot, localize: localize)
        case .attention:
            return attentionSections(for: snapshot, localize: localize)
        case .servers:
            return serverSections(for: snapshot, localize: localize)
        }
    }

    public static func sections(
        for snapshot: CmuxExtensionSidebarSnapshot,
        localize: Localize = { $0.defaultValue }
    ) -> [CmuxExtensionWorkspaceTreeSection] {
        projectTreeSections(for: snapshot, localize: localize)
    }

    private static func projectTreeSections(
        for snapshot: CmuxExtensionSidebarSnapshot,
        localize: Localize
    ) -> [CmuxExtensionWorkspaceTreeSection] {
        var sections: [CmuxExtensionWorkspaceTreeSection] = []

        let pinned = snapshot.workspaces.filter(\.isPinned)
        if !pinned.isEmpty {
            let title = CmuxExtensionLocalizedText(
                key: "sidebar.tree.group.pinned",
                defaultValue: "Pinned"
            )
            sections.append(
                CmuxExtensionWorkspaceTreeSection(
                    id: "pinned",
                    title: localize(title),
                    titleText: title,
                    subtitle: nil,
                    systemImageName: "pin",
                    projectRootPath: nil,
                    workspaceIds: pinned.map(\.id)
                )
            )
        }

        var grouped: [String: CmuxExtensionWorkspaceTreeSection] = [:]
        var orderedGroupIds: [String] = []

        for workspace in snapshot.workspaces where !workspace.isPinned {
            let group = groupSectionTemplate(for: workspace, localize: localize)
            if grouped[group.id] == nil {
                grouped[group.id] = group
                orderedGroupIds.append(group.id)
            }
            guard var current = grouped[group.id] else { continue }
            current = CmuxExtensionWorkspaceTreeSection(
                id: current.id,
                title: current.title,
                titleText: current.titleText,
                subtitle: current.subtitle,
                subtitleText: current.subtitleText,
                systemImageName: current.systemImageName,
                projectRootPath: current.projectRootPath,
                workspaceIds: current.workspaceIds + [workspace.id]
            )
            grouped[group.id] = current
        }

        sections.append(contentsOf: orderedGroupIds.compactMap { grouped[$0] })
        return sections
    }

    private static func attentionSections(
        for snapshot: CmuxExtensionSidebarSnapshot,
        localize: Localize
    ) -> [CmuxExtensionWorkspaceTreeSection] {
        var sections: [CmuxExtensionWorkspaceTreeSection] = []
        let selectedId = snapshot.selectedWorkspaceId

        appendSection(
            id: "attention:active",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.custom.group.active",
                defaultValue: "Active"
            ),
            systemImageName: "circle.fill",
            workspaces: snapshot.workspaces.filter { $0.id == selectedId },
            localize: localize,
            to: &sections
        )
        appendSection(
            id: "attention:pinned",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.tree.group.pinned",
                defaultValue: "Pinned"
            ),
            systemImageName: "pin",
            workspaces: snapshot.workspaces.filter { $0.isPinned && $0.id != selectedId },
            localize: localize,
            to: &sections
        )
        appendSection(
            id: "attention:needs-attention",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.custom.group.attention",
                defaultValue: "Needs Attention"
            ),
            systemImageName: "bell",
            workspaces: snapshot.workspaces.filter {
                $0.id != selectedId && !$0.isPinned && needsAttention($0)
            },
            localize: localize,
            to: &sections
        )
        appendSection(
            id: "attention:quiet",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.custom.group.quiet",
                defaultValue: "Quiet"
            ),
            systemImageName: "checkmark.circle",
            workspaces: snapshot.workspaces.filter {
                $0.id != selectedId && !$0.isPinned && !needsAttention($0)
            },
            localize: localize,
            to: &sections
        )

        return sections
    }

    private static func serverSections(
        for snapshot: CmuxExtensionSidebarSnapshot,
        localize: Localize
    ) -> [CmuxExtensionWorkspaceTreeSection] {
        var sections: [CmuxExtensionWorkspaceTreeSection] = []

        appendSection(
            id: "servers:pinned",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.tree.group.pinned",
                defaultValue: "Pinned"
            ),
            systemImageName: "pin",
            workspaces: snapshot.workspaces.filter(\.isPinned),
            localize: localize,
            to: &sections
        )
        appendSection(
            id: "servers:live",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.custom.group.liveServers",
                defaultValue: "Live Servers"
            ),
            systemImageName: "terminal",
            workspaces: snapshot.workspaces.filter { !$0.isPinned && hasServerSignal($0) },
            localize: localize,
            to: &sections
        )
        appendSection(
            id: "servers:remote",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.custom.group.remote",
                defaultValue: "Remote"
            ),
            systemImageName: "network",
            workspaces: snapshot.workspaces.filter {
                !$0.isPinned && !hasServerSignal($0) && trimmedNonEmpty($0.remoteDisplayTarget) != nil
            },
            localize: localize,
            to: &sections
        )
        appendSection(
            id: "servers:local",
            title: CmuxExtensionLocalizedText(
                key: "sidebar.custom.group.local",
                defaultValue: "Local Workspaces"
            ),
            systemImageName: "folder",
            workspaces: snapshot.workspaces.filter {
                !$0.isPinned && !hasServerSignal($0) && trimmedNonEmpty($0.remoteDisplayTarget) == nil
            },
            localize: localize,
            to: &sections
        )

        return sections
    }

    private static func groupSectionTemplate(
        for workspace: CmuxExtensionWorkspaceSnapshot,
        localize: Localize
    ) -> CmuxExtensionWorkspaceTreeSection {
        if let remoteTarget = trimmedNonEmpty(workspace.remoteDisplayTarget) {
            let subtitle = CmuxExtensionLocalizedText(
                key: "sidebar.tree.group.remote.subtitle",
                defaultValue: "SSH"
            )
            return CmuxExtensionWorkspaceTreeSection(
                id: "remote:\(remoteTarget)",
                title: remoteTarget,
                subtitle: localize(subtitle),
                subtitleText: subtitle,
                systemImageName: "network",
                projectRootPath: nil,
                workspaceIds: []
            )
        }

        guard let rootPath = trimmedNonEmpty(workspace.rootPath) else {
            let title = CmuxExtensionLocalizedText(
                key: "sidebar.tree.group.other",
                defaultValue: "Other"
            )
            let subtitle = CmuxExtensionLocalizedText(
                key: "sidebar.tree.group.other.subtitle",
                defaultValue: "No folder"
            )
            return CmuxExtensionWorkspaceTreeSection(
                id: "other",
                title: localize(title),
                titleText: title,
                subtitle: localize(subtitle),
                subtitleText: subtitle,
                systemImageName: "tray",
                projectRootPath: nil,
                workspaceIds: []
            )
        }

        let url = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let groupURL = trimmedNonEmpty(workspace.projectRootPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? url.deletingLastPathComponent()
        let groupPath = groupURL.path
        let title = groupURL.lastPathComponent.isEmpty ? CmuxExtensionPathFormatter.shortenedPath(groupPath) : groupURL.lastPathComponent
        let subtitle = CmuxExtensionPathFormatter.shortenedPath(groupPath)

        return CmuxExtensionWorkspaceTreeSection(
            id: "folder:\(groupPath)",
            title: title.isEmpty ? "/" : title,
            subtitle: subtitle,
            systemImageName: "folder",
            projectRootPath: groupPath,
            workspaceIds: []
        )
    }

    private static func appendSection(
        id: String,
        title: CmuxExtensionLocalizedText,
        systemImageName: String,
        workspaces: [CmuxExtensionWorkspaceSnapshot],
        localize: Localize,
        to sections: inout [CmuxExtensionWorkspaceTreeSection]
    ) {
        guard !workspaces.isEmpty else { return }
        sections.append(
            CmuxExtensionWorkspaceTreeSection(
                id: id,
                title: localize(title),
                titleText: title,
                subtitle: nil,
                systemImageName: systemImageName,
                projectRootPath: nil,
                workspaceIds: workspaces.map(\.id)
            )
        )
    }

    private static func needsAttention(_ workspace: CmuxExtensionWorkspaceSnapshot) -> Bool {
        workspace.unreadCount > 0 ||
            trimmedNonEmpty(workspace.latestNotificationText) != nil ||
            workspace.remoteConnectionState == "connecting" ||
            workspace.remoteConnectionState == "reconnecting" ||
            workspace.remoteConnectionState == "disconnected"
    }

    private static func hasServerSignal(_ workspace: CmuxExtensionWorkspaceSnapshot) -> Bool {
        if !workspace.listeningPorts.isEmpty {
            return true
        }
        guard let description = trimmedNonEmpty(workspace.customDescription)?.lowercased() else {
            return false
        }
        return description.contains("server") || description.contains(":")
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum CmuxExtensionPathFormatter {
    public static let homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path

    public static func shortenedPath(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == homeDirectoryPath {
            return "~"
        }
        if trimmed.hasPrefix(homeDirectoryPath + "/") {
            return "~" + trimmed.dropFirst(homeDirectoryPath.count)
        }
        return trimmed
    }
}

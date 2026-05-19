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

public enum CmuxExtensionJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CmuxExtensionJSONValue])
    case object([String: CmuxExtensionJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CmuxExtensionJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CmuxExtensionJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .number(let value):
            let rounded = value.rounded()
            guard rounded == value else { return nil }
            return Int(rounded)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
}

public struct CmuxExtensionEventFrame: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var name: String
    public var category: String
    public var source: String
    public var occurredAt: Date
    public var workspaceId: UUID?
    public var surfaceId: UUID?
    public var paneId: UUID?
    public var windowId: UUID?
    public var payload: [String: CmuxExtensionJSONValue]

    public init(
        sequence: UInt64,
        name: String,
        category: String,
        source: String,
        occurredAt: Date,
        workspaceId: UUID?,
        surfaceId: UUID? = nil,
        paneId: UUID? = nil,
        windowId: UUID? = nil,
        payload: [String: CmuxExtensionJSONValue] = [:]
    ) {
        self.sequence = sequence
        self.name = name
        self.category = category
        self.source = source
        self.occurredAt = occurredAt
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.paneId = paneId
        self.windowId = windowId
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case name
        case category
        case source
        case occurredAt = "occurred_at"
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case paneId = "pane_id"
        case windowId = "window_id"
        case payload
    }
}

public struct CmuxExtensionCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var payload: [String: CmuxExtensionJSONValue]

    public init(ok: Bool, payload: [String: CmuxExtensionJSONValue] = [:]) {
        self.ok = ok
        self.payload = payload
    }
}

public struct CmuxClient: Sendable {
    public var snapshot: @Sendable () async throws -> CmuxExtensionSidebarSnapshot
    public var events: @Sendable (_ afterSequence: UInt64?) -> AsyncThrowingStream<CmuxExtensionEventFrame, Error>
    public var dispatch: @Sendable (_ mutation: CmuxExtensionSidebarMutation) async throws -> CmuxExtensionCommandResult

    public init(
        snapshot: @escaping @Sendable () async throws -> CmuxExtensionSidebarSnapshot,
        events: @escaping @Sendable (_ afterSequence: UInt64?) -> AsyncThrowingStream<CmuxExtensionEventFrame, Error>,
        dispatch: @escaping @Sendable (_ mutation: CmuxExtensionSidebarMutation) async throws -> CmuxExtensionCommandResult
    ) {
        self.snapshot = snapshot
        self.events = events
        self.dispatch = dispatch
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
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAt = latestSubmittedAt
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

    public static func reduce(
        _ snapshot: CmuxExtensionSidebarSnapshot,
        event frame: CmuxExtensionEventFrame
    ) -> CmuxExtensionSidebarSnapshot {
        var next = snapshot
        next.sequence = max(snapshot.sequence, frame.sequence)

        switch frame.name {
        case "workspace.closed":
            guard let workspaceId = resolvedWorkspaceId(frame) else { return next }
            next.workspaces.removeAll { $0.id == workspaceId }
            if next.selectedWorkspaceId == workspaceId {
                next.selectedWorkspaceId = nil
            }

        case "workspace.selected":
            next.selectedWorkspaceId = resolvedWorkspaceId(frame)

        case "workspace.renamed":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }),
                  let title = frame.payload["title"]?.stringValue ?? frame.payload["custom_title"]?.stringValue else {
                return next
            }
            next.workspaces[index].title = title

        case "workspace.reordered":
            let order = frame.payload["workspace_ids"]?.uuidArrayValue
                ?? frame.payload["order"]?.uuidArrayValue
                ?? frame.payload["ids"]?.uuidArrayValue
            if let order {
                next = reduce(next, event: .workspacesReordered(order))
                next.sequence = max(next.sequence, frame.sequence)
            }

        case "workspace.prompt.submitted":
            guard let workspaceId = resolvedWorkspaceId(frame),
                  let index = next.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
                return next
            }
            let message = frame.payload["message"]?.stringValue
                ?? frame.payload["message_preview"]?.stringValue
                ?? frame.payload["prompt"]?.stringValue
            next.workspaces[index].latestSubmittedMessage = normalizedPrompt(message)
            next.workspaces[index].latestSubmittedAt = frame.occurredAt

        default:
            break
        }

        return next
    }

    private static func resolvedWorkspaceId(_ frame: CmuxExtensionEventFrame) -> UUID? {
        frame.workspaceId
            ?? frame.payload["workspace_id"]?.uuidValue
            ?? frame.payload["id"]?.uuidValue
    }

    private static func normalizedPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

public enum CmuxExtensionSidebarProviderID {
    public static let defaultWorkspaces = "cmux.sidebar.default"
}

public enum CmuxExtensionSidebarPresentation: String, Codable, Equatable, Sendable {
    case tree
    case browserStack = "browser-stack"
}

public struct CmuxExtensionSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: CmuxExtensionLocalizedText
    public var subtitle: CmuxExtensionLocalizedText?
    public var systemImageName: String
    public var isHostProvided: Bool

    public init(
        id: String,
        title: CmuxExtensionLocalizedText,
        subtitle: CmuxExtensionLocalizedText?,
        systemImageName: String,
        isHostProvided: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
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
        isHostProvided: true
    )
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

    public static let allCases: [CmuxExtensionWorkspacePopoverTab] = [.notes, .browser]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.notes.rawValue:
            self = .notes
        case Self.browser.rawValue, Self.pullRequest.rawValue:
            self = .browser
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown workspace popover tab: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .notes:
            try container.encode(Self.notes.rawValue)
        case .browser, .pullRequest:
            try container.encode(Self.browser.rawValue)
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case providerId
        case snapshotSequence
        case sections
        case presentation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        snapshotSequence = try container.decode(UInt64.self, forKey: .snapshotSequence)
        sections = try container.decode([CmuxExtensionSidebarRenderSection].self, forKey: .sections)
        presentation = try container.decodeIfPresent(
            CmuxExtensionSidebarPresentation.self,
            forKey: .presentation
        ) ?? .tree
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerId, forKey: .providerId)
        try container.encode(snapshotSequence, forKey: .snapshotSequence)
        try container.encode(sections, forKey: .sections)
        try container.encode(presentation, forKey: .presentation)
    }
}

public extension CmuxExtensionSidebarRenderModel {
    var relativeTextDates: [Date] {
        sections.flatMap { section in
            section.rows.flatMap { row in
                [row.subtitle?.relativeDate, row.trailingText?.relativeDate].compactMap { $0 }
            }
        }
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

public struct CmuxExtensionSidebarRenderContext: Codable, Equatable, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }

    public static var current: CmuxExtensionSidebarRenderContext {
        CmuxExtensionSidebarRenderContext(now: Date())
    }
}

public protocol CmuxExtensionSidebarProvider: Sendable {
    var descriptor: CmuxExtensionSidebarProviderDescriptor { get }

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel
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
    func render(snapshot: CmuxExtensionSidebarSnapshot, context: CmuxExtensionSidebarRenderContext) -> CmuxExtensionSidebarRenderModel {
        render(snapshot: snapshot)
    }
}

private extension CmuxExtensionJSONValue {
    var uuidValue: UUID? {
        stringValue.flatMap(UUID.init(uuidString:))
    }

    var uuidArrayValue: [UUID]? {
        guard case .array(let values) = self else { return nil }
        let ids = values.compactMap(\.uuidValue)
        return ids.count == values.count ? ids : nil
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

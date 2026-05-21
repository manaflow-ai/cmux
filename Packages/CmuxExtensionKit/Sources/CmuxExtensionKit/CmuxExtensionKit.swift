import Foundation

private enum CmuxExtensionDateCoding {
    static func iso8601Date(from string: String) -> Date? {
        let fractional = formatter(
            key: "cmux.extension.iso8601.fractional",
            options: [.withInternetDateTime, .withFractionalSeconds]
        )
        if let date = fractional.date(from: string) {
            return date
        }

        let plain = formatter(
            key: "cmux.extension.iso8601.plain",
            options: [.withInternetDateTime]
        )
        return plain.date(from: string)
    }

    static func iso8601String(from date: Date) -> String {
        formatter(
            key: "cmux.extension.iso8601.encode",
            options: [.withInternetDateTime, .withFractionalSeconds]
        ).string(from: date)
    }

    private static func formatter(
        key: String,
        options: ISO8601DateFormatter.Options
    ) -> ISO8601DateFormatter {
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[key] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        dictionary[key] = formatter
        return formatter
    }
}

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
    public var windowId: UUID?
    public var selectedWorkspaceId: UUID?
    public var workspaces: [CmuxExtensionWorkspaceSnapshot]

    public init(
        sequence: UInt64,
        selectedWorkspaceId: UUID?,
        workspaces: [CmuxExtensionWorkspaceSnapshot],
        windowId: UUID? = nil
    ) {
        self.sequence = sequence
        self.windowId = windowId
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
    }

    public var workspaceIds: [UUID] {
        workspaces.map(\.id)
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case windowId
        case selectedWorkspaceId
        case workspaces
    }

    private enum SocketCodingKeys: String, CodingKey {
        case sequence
        case seq
        case windowId = "window_id"
        case selectedWorkspaceId = "selected_workspace_id"
        case workspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let socketContainer = try decoder.container(keyedBy: SocketCodingKeys.self)
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
            ?? socketContainer.decodeIfPresent(UInt64.self, forKey: .sequence)
            ?? socketContainer.decodeIfPresent(UInt64.self, forKey: .seq)
            ?? 0
        windowId = try container.decodeIfPresent(UUID.self, forKey: .windowId)
            ?? socketContainer.decodeIfPresent(UUID.self, forKey: .windowId)
        selectedWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
            ?? socketContainer.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
        workspaces = try container.decodeIfPresent([CmuxExtensionWorkspaceSnapshot].self, forKey: .workspaces)
            ?? socketContainer.decodeIfPresent([CmuxExtensionWorkspaceSnapshot].self, forKey: .workspaces)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(windowId, forKey: .windowId)
        try container.encodeIfPresent(selectedWorkspaceId, forKey: .selectedWorkspaceId)
        try container.encode(workspaces, forKey: .workspaces)
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
            return Int(exactly: value)
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(String.self, forKey: .category)
        source = try container.decode(String.self, forKey: .source)
        if let date = try? container.decode(Date.self, forKey: .occurredAt) {
            occurredAt = date
        } else {
            let string = try container.decode(String.self, forKey: .occurredAt)
            guard let date = CmuxExtensionDateCoding.iso8601Date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .occurredAt,
                    in: container,
                    debugDescription: "Invalid ISO-8601 event timestamp."
                )
            }
            occurredAt = date
        }
        workspaceId = try container.decodeIfPresent(UUID.self, forKey: .workspaceId)
        surfaceId = try container.decodeIfPresent(UUID.self, forKey: .surfaceId)
        paneId = try container.decodeIfPresent(UUID.self, forKey: .paneId)
        windowId = try container.decodeIfPresent(UUID.self, forKey: .windowId)
        payload = try container.decodeIfPresent([String: CmuxExtensionJSONValue].self, forKey: .payload) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(source, forKey: .source)
        try container.encode(CmuxExtensionDateCoding.iso8601String(from: occurredAt), forKey: .occurredAt)
        try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(surfaceId, forKey: .surfaceId)
        try container.encodeIfPresent(paneId, forKey: .paneId)
        try container.encodeIfPresent(windowId, forKey: .windowId)
        try container.encode(payload, forKey: .payload)
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

public struct CmuxExtensionGitBranchSnapshot: Codable, Equatable, Sendable {
    public var branch: String
    public var isDirty: Bool

    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }

    private enum CodingKeys: String, CodingKey {
        case branch
        case isDirty
    }

    private enum SocketCodingKeys: String, CodingKey {
        case branch
        case isDirty = "dirty"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let socketContainer = try decoder.container(keyedBy: SocketCodingKeys.self)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
            ?? socketContainer.decode(String.self, forKey: .branch)
        isDirty = try container.decodeIfPresent(Bool.self, forKey: .isDirty)
            ?? socketContainer.decodeIfPresent(Bool.self, forKey: .isDirty)
            ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(branch, forKey: .branch)
        try container.encode(isDirty, forKey: .isDirty)
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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case customDescription
        case isPinned
        case rootPath
        case projectRootPath
        case branchSummary
        case remoteDisplayTarget
        case remoteConnectionState
        case unreadCount
        case latestNotificationText
        case latestSubmittedMessage
        case latestSubmittedAt
        case listeningPorts
        case pullRequestURLs
        case panelDirectories
        case gitBranches
    }

    private enum SocketCodingKeys: String, CodingKey {
        case id
        case title
        case customDescription = "description"
        case isPinned = "pinned"
        case rootPath = "root_path"
        case projectRootPath = "project_root_path"
        case branchSummary = "branch_summary"
        case remoteDisplayTarget = "remote_display_target"
        case remoteConnectionState = "remote_connection_state"
        case unreadCount = "unread_count"
        case latestNotificationText = "latest_notification_text"
        case latestSubmittedMessage = "latest_submitted_message"
        case latestSubmittedAt = "latest_submitted_at"
        case listeningPorts = "listening_ports"
        case pullRequestURLs = "pull_request_urls"
        case panelDirectories = "panel_directories"
        case gitBranches = "git_branches"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let socketContainer = try decoder.container(keyedBy: SocketCodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id)
            ?? socketContainer.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? socketContainer.decode(String.self, forKey: .title)
        customDescription = try container.decodeIfPresent(String.self, forKey: .customDescription)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .customDescription)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
            ?? socketContainer.decodeIfPresent(Bool.self, forKey: .isPinned)
            ?? false
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .rootPath)
        projectRootPath = try container.decodeIfPresent(String.self, forKey: .projectRootPath)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .projectRootPath)
        branchSummary = try container.decodeIfPresent(String.self, forKey: .branchSummary)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .branchSummary)
        remoteDisplayTarget = try container.decodeIfPresent(String.self, forKey: .remoteDisplayTarget)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .remoteDisplayTarget)
        remoteConnectionState = try container.decodeIfPresent(String.self, forKey: .remoteConnectionState)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .remoteConnectionState)
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
            ?? socketContainer.decodeIfPresent(Int.self, forKey: .unreadCount)
            ?? 0
        latestNotificationText = try container.decodeIfPresent(String.self, forKey: .latestNotificationText)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .latestNotificationText)
        latestSubmittedMessage = try container.decodeIfPresent(String.self, forKey: .latestSubmittedMessage)
            ?? socketContainer.decodeIfPresent(String.self, forKey: .latestSubmittedMessage)
        latestSubmittedAt = try Self.decodeDate(
            container: container,
            camelKey: .latestSubmittedAt,
            socketContainer: socketContainer,
            socketKey: .latestSubmittedAt
        )
        listeningPorts = try container.decodeIfPresent([Int].self, forKey: .listeningPorts)
            ?? socketContainer.decodeIfPresent([Int].self, forKey: .listeningPorts)
            ?? []
        pullRequestURLs = try container.decodeIfPresent([String].self, forKey: .pullRequestURLs)
            ?? socketContainer.decodeIfPresent([String].self, forKey: .pullRequestURLs)
            ?? []
        panelDirectories = try container.decodeIfPresent([String].self, forKey: .panelDirectories)
            ?? socketContainer.decodeIfPresent([String].self, forKey: .panelDirectories)
            ?? []
        gitBranches = try container.decodeIfPresent([CmuxExtensionGitBranchSnapshot].self, forKey: .gitBranches)
            ?? socketContainer.decodeIfPresent([CmuxExtensionGitBranchSnapshot].self, forKey: .gitBranches)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(customDescription, forKey: .customDescription)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(rootPath, forKey: .rootPath)
        try container.encodeIfPresent(projectRootPath, forKey: .projectRootPath)
        try container.encodeIfPresent(branchSummary, forKey: .branchSummary)
        try container.encodeIfPresent(remoteDisplayTarget, forKey: .remoteDisplayTarget)
        try container.encodeIfPresent(remoteConnectionState, forKey: .remoteConnectionState)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encodeIfPresent(latestNotificationText, forKey: .latestNotificationText)
        try container.encodeIfPresent(latestSubmittedMessage, forKey: .latestSubmittedMessage)
        try container.encodeIfPresent(latestSubmittedAt, forKey: .latestSubmittedAt)
        try container.encode(listeningPorts, forKey: .listeningPorts)
        try container.encode(pullRequestURLs, forKey: .pullRequestURLs)
        try container.encode(panelDirectories, forKey: .panelDirectories)
        try container.encode(gitBranches, forKey: .gitBranches)
    }

    private static func decodeDate(
        container: KeyedDecodingContainer<CodingKeys>,
        camelKey: CodingKeys,
        socketContainer: KeyedDecodingContainer<SocketCodingKeys>,
        socketKey: SocketCodingKeys
    ) throws -> Date? {
        if let date = try container.decodeIfPresent(Date.self, forKey: camelKey) {
            return date
        }
        if let date = try? socketContainer.decodeIfPresent(Date.self, forKey: socketKey) {
            return date
        }
        guard let string = try socketContainer.decodeIfPresent(String.self, forKey: socketKey) else {
            return nil
        }
        return CmuxExtensionDateCoding.iso8601Date(from: string)
    }
}

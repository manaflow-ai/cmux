import Foundation

/// Versioned messages exchanged by the native acpmux model and its optional
/// TypeScript renderer. The web view is a presentation layer: all values are
/// snapshots of model state and all mutations travel back through requests.
public enum AcpmuxWebBridgeProtocol {
    public static let version = 1
}

public struct AcpmuxWebRow: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let version: Int
    public let at: Int64
    public let kind: String
    public let text: String?
    public let streaming: Bool?
    public let pending: Bool?
    public let failed: Bool?
    public let items: [AcpmuxWebActivityItem]?
    public let toolCount: Int?
    public let durationMs: Int64?
    public let status: String?
    public let error: String?
    public let permission: AcpmuxWebPermission?

    public init(row: TranscriptRow) {
        id = row.id
        version = row.version
        at = row.at
        var resolvedKind = "notice"
        var resolvedText: String?
        var resolvedStreaming: Bool?
        var resolvedPending: Bool?
        var resolvedFailed: Bool?
        var resolvedItems: [AcpmuxWebActivityItem]?
        var resolvedToolCount: Int?
        var resolvedDurationMs: Int64?
        var resolvedStatus: String?
        var resolvedError: String?
        var resolvedPermission: AcpmuxWebPermission?
        switch row.content {
        case .user(let message):
            resolvedKind = "user"
            resolvedText = message.text
            resolvedPending = message.isPending
            resolvedFailed = message.failed
        case .assistant(let body, let isStreaming):
            resolvedKind = "assistant"
            resolvedText = body
            resolvedStreaming = isStreaming
        case .activity(let group):
            resolvedKind = "activity"
            resolvedItems = group.items.map(AcpmuxWebActivityItem.init)
            resolvedStatus = group.isLive ? "live" : "done"
            resolvedToolCount = group.toolCount
        case .plan(let entries):
            resolvedKind = "plan"
            resolvedItems = entries.map { AcpmuxWebActivityItem(text: $0.content, kind: "plan", status: $0.status) }
        case .permission(let card):
            resolvedKind = "permission"
            resolvedPermission = AcpmuxWebPermission(card: card)
        case .turnSummary(let summary):
            resolvedKind = "turnSummary"
            resolvedDurationMs = summary.durationMs
            resolvedToolCount = summary.toolCount
            resolvedStatus = summary.status
            resolvedError = summary.error
        case .typing:
            resolvedKind = "typing"
        case .notice(let notice):
            resolvedKind = "notice"
            resolvedText = notice
        }
        kind = resolvedKind
        text = resolvedText
        streaming = resolvedStreaming
        pending = resolvedPending
        failed = resolvedFailed
        items = resolvedItems
        toolCount = resolvedToolCount
        durationMs = resolvedDurationMs
        status = resolvedStatus
        error = resolvedError
        permission = resolvedPermission
    }
}

public struct AcpmuxWebActivityItem: Codable, Sendable, Hashable {
    public let kind: String
    public let text: String
    public let status: String?
    public let tool: AcpmuxWebTool?

    public init(text: String, kind: String, status: String? = nil) {
        self.kind = kind
        self.text = text
        self.status = status
        self.tool = nil
    }

    init(_ item: TranscriptActivityItem) {
        switch item {
        case .thought(let text):
            self.init(text: text, kind: "thought")
        case .tool(let tool):
            kind = "tool"
            text = tool.title
            status = tool.status
            self.tool = AcpmuxWebTool(tool: tool)
        }
    }
}

public struct AcpmuxWebTool: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let kind: String?
    public let status: String
    public let inputSummary: String?
    public let output: String?

    init(tool: TranscriptToolCall) {
        id = tool.id
        title = tool.title
        kind = tool.kind
        status = tool.status
        inputSummary = tool.inputSummary
        output = tool.output
    }
}

public struct AcpmuxWebPermission: Codable, Sendable, Hashable {
    public let permissionId: String
    public let title: String?
    public let kind: String?
    public let options: [AcpmuxWebPermissionOption]
    public let pending: Bool

    public init(card: TranscriptPermissionCard) {
        permissionId = card.permissionId
        title = card.request.toolCall?.title
        kind = card.request.toolCall?.kind
        options = card.request.options.map {
            AcpmuxWebPermissionOption(id: $0.optionId, name: $0.name, allow: $0.isAllow)
        }
        pending = card.isPending
    }
}

public struct AcpmuxWebPermissionOption: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let allow: Bool

    init(id: String, name: String, allow: Bool) {
        self.id = id
        self.name = name
        self.allow = allow
    }
}

public struct AcpmuxWebQueueEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: String
    public let queuedAt: Int64?

    public init(_ entry: AcpmuxQueueEntry) {
        id = entry.promptId
        prompt = entry.text ?? ""
        queuedAt = nil
    }
}

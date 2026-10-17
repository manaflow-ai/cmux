import CmuxAgentChat
import CmuxMobileRPC
import Foundation

/// The Mac Chief control surface exposed to the classic iOS app.
///
/// Chief is a Mac-owned conversation, so it deliberately has a separate wire
/// model from ``ChatSessionDescriptor``/``MobileChatEventSource``. The latter
/// describes a terminal-backed agent session and its transcript; Chief's
/// `chief.*` methods describe a conversation list and a compact transcript
/// projection. Keeping that boundary explicit lets the UI share the Messages
/// style without treating a Chief conversation as a terminal session.
public enum MobileChiefCapability {
    public static let status = "chief.status"
    public static let conversations = "chief.conversations"
    public static let read = "chief.read"
    public static let send = "chief.send"
    public static let stop = "chief.stop"
    public static let approve = "chief.approve"
    public static let answer = "chief.answer"
    public static let open = "chief.open"

    /// Chief is available when the host advertises its read path. Older Chief
    /// builds may omit the optional action methods, so callers should gate
    /// those actions independently before presenting buttons.
    public static func isAvailable(in capabilities: Set<String>) -> Bool {
        capabilities.contains(conversations) || capabilities.contains(status)
    }
}

/// `chief.status` result.
public struct MobileChiefStatus: Codable, Equatable, Sendable {
    public let started: Bool
    public let startFailure: String?
    public let home: String?
    public let harness: String
    public let harnessName: String
    public let model: String
    public let effort: String
    public let unread: Int
    public let conversationCount: Int
    public let working: [String]
    public let defaultConversation: String

    public init(
        started: Bool,
        startFailure: String? = nil,
        home: String? = nil,
        harness: String = "",
        harnessName: String = "",
        model: String = "",
        effort: String = "",
        unread: Int = 0,
        conversationCount: Int = 0,
        working: [String] = [],
        defaultConversation: String = ""
    ) {
        self.started = started
        self.startFailure = startFailure
        self.home = home
        self.harness = harness
        self.harnessName = harnessName
        self.model = model
        self.effort = effort
        self.unread = unread
        self.conversationCount = conversationCount
        self.working = working
        self.defaultConversation = defaultConversation
    }

    private enum CodingKeys: String, CodingKey {
        case started, startFailure = "start_failure", home, harness
        case harnessName = "harness_name", model, effort, unread
        case conversationCount = "conversation_count", working
        case defaultConversation = "default_conversation"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        started = try c.decodeIfPresent(Bool.self, forKey: .started) ?? false
        startFailure = try c.decodeIfPresent(String.self, forKey: .startFailure)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? ""
        harnessName = try c.decodeIfPresent(String.self, forKey: .harnessName) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? ""
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        conversationCount = try c.decodeIfPresent(Int.self, forKey: .conversationCount) ?? 0
        working = try c.decodeIfPresent([String].self, forKey: .working) ?? []
        defaultConversation = try c.decodeIfPresent(String.self, forKey: .defaultConversation) ?? ""
    }
}

/// One row from `chief.conversations`.
public struct MobileChiefConversation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let preview: String
    public let unread: Int
    public let pinned: Bool
    public let working: Bool
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        preview: String = "",
        unread: Int = 0,
        pinned: Bool = false,
        working: Bool = false,
        updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.unread = unread
        self.pinned = pinned
        self.working = working
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, unread, pinned, working
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        working = try c.decodeIfPresent(Bool.self, forKey: .working) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

/// One compact transcript message from `chief.read`.
public struct MobileChiefMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let seq: UInt64
    public let authorID: String
    public let author: String
    public let authorKind: String
    public let text: String
    public let at: Date
    /// Part kinds (`text`, `work`, `approval`, `question`, …). The Mac
    /// endpoint intentionally returns kinds, not the private Home payloads.
    public let parts: [String]
    public let threadRoot: String?

    public init(
        id: String,
        seq: UInt64,
        authorID: String,
        author: String,
        authorKind: String,
        text: String,
        at: Date,
        parts: [String] = [],
        threadRoot: String? = nil
    ) {
        self.id = id
        self.seq = seq
        self.authorID = authorID
        self.author = author
        self.authorKind = authorKind
        self.text = text
        self.at = at
        self.parts = parts
        self.threadRoot = threadRoot
    }

    private enum CodingKeys: String, CodingKey {
        case id, seq, authorID = "author_id", author, authorKind = "author_kind"
        case text, at, parts, threadRoot = "thread_root"
    }
}

/// `chief.read` result. Messages are ordered oldest to newest by the Mac.
public struct MobileChiefReadResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let working: Bool
    public let messages: [MobileChiefMessage]

    public init(conversation: String, working: Bool = false, messages: [MobileChiefMessage] = []) {
        self.conversation = conversation
        self.working = working
        self.messages = messages
    }
}

/// `chief.send` result.
public struct MobileChiefSendResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let messageID: String?
    public let queued: Bool

    public init(conversation: String, messageID: String? = nil, queued: Bool = false) {
        self.conversation = conversation
        self.messageID = messageID
        self.queued = queued
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, messageID = "message_id", queued
    }
}

/// `chief.approve` result.
public struct MobileChiefApprovalResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let request: String
    public let choice: String
    public let decided: Bool
}

/// `chief.answer` result.
public struct MobileChiefAnswerResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let message: String
    public let answer: [String]
}

/// `chief.open` result.
public struct MobileChiefOpenResult: Codable, Equatable, Sendable {
    public let windowID: String?
    public let opened: Bool

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id", opened
    }
}

/// Thin async client for Austin's Mac Chief control API.
///
/// The Mac does not publish a Chief event topic yet. Callers should refresh
/// `conversations()`/`read()` after a send and on app foreground or reconnect.
public actor MobileChiefClient {
    private let client: MobileCoreRPCClient
    private let coding = ChatWireCoding()

    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    public func status() async throws -> MobileChiefStatus {
        try await request("chief.status", params: [:], as: MobileChiefStatus.self)
    }

    public func conversations() async throws -> [MobileChiefConversation] {
        let result = try await request("chief.conversations", params: [:], as: MobileChiefConversationsResult.self)
        return result.conversations
    }

    public func read(conversation: String? = nil, limit: Int = 20) async throws -> MobileChiefReadResult {
        var params: [String: Any] = ["limit": max(1, min(limit, 200))]
        if let conversation { params["conversation"] = conversation }
        return try await request("chief.read", params: params, as: MobileChiefReadResult.self)
    }

    public func send(
        _ text: String,
        conversation: String? = nil,
        from: String? = nil,
        startTurn: Bool = true
    ) async throws -> MobileChiefSendResult {
        var params: [String: Any] = ["text": text, "start_turn": startTurn]
        if let conversation { params["conversation"] = conversation }
        if let from { params["from"] = from }
        return try await request("chief.send", params: params, as: MobileChiefSendResult.self)
    }

    public func stop(conversation: String? = nil) async throws -> MobileChiefStopResult {
        var params: [String: Any] = [:]
        if let conversation { params["conversation"] = conversation }
        return try await request("chief.stop", params: params, as: MobileChiefStopResult.self)
    }

    public func approve(
        conversation: String? = nil,
        request: String? = nil,
        choice: String
    ) async throws -> MobileChiefApprovalResult {
        var params: [String: Any] = ["choice": choice]
        if let conversation { params["conversation"] = conversation }
        if let request { params["request"] = request }
        return try await request("chief.approve", params: params, as: MobileChiefApprovalResult.self)
    }

    public func answer(
        conversation: String? = nil,
        message: String? = nil,
        choices: [String] = [],
        text: String? = nil
    ) async throws -> MobileChiefAnswerResult {
        var params: [String: Any] = ["choices": choices]
        if let conversation { params["conversation"] = conversation }
        if let message { params["message"] = message }
        if let text { params["text"] = text }
        return try await request("chief.answer", params: params, as: MobileChiefAnswerResult.self)
    }

    public func open(windowID: String? = nil, workspaceID: String? = nil) async throws -> MobileChiefOpenResult {
        var params: [String: Any] = [:]
        if let windowID { params["window_id"] = windowID }
        if let workspaceID { params["workspace_id"] = workspaceID }
        return try await request("chief.open", params: params, as: MobileChiefOpenResult.self)
    }

    private func request<T: Decodable>(_ method: String, params: [String: Any], as type: T.Type) async throws -> T {
        let request = try MobileCoreRPCClient.requestData(method: method, params: params)
        let result = try await client.sendRequest(request)
        return try coding.decode(type, from: result)
    }
}

private struct MobileChiefConversationsResult: Decodable {
    let conversations: [MobileChiefConversation]
}

public struct MobileChiefStopResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let stopped: Bool
}

import CmuxAgentChat
public import CmuxAgentQuestion
public import CmuxMobileRPC
public import Foundation

/// The Mac Chief control surface exposed to the classic iOS app.
///
/// Chief is a Mac-owned conversation, so it deliberately has a separate wire
/// model from ``ChatSessionDescriptor``/``MobileChatEventSource``. The latter
/// describes a terminal-backed agent session and its transcript; Chief's
/// `chief.*` methods describe a conversation list and a compact transcript
/// projection. Keeping that boundary explicit lets the UI share the Messages
/// style without treating a Chief conversation as a terminal session.
public struct MobileChiefCapability: Hashable, Sendable {
    /// The wire capability name. The instance form keeps this type usable as
    /// a value while the static names remain convenient for capability sets.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let status = "chief.status"
    public static let conversations = "chief.conversations"
    public static let read = "chief.read"
    public static let markRead = "chief.mark_read"
    public static let send = "chief.send"
    public static let stop = "chief.stop"
    public static let approve = "chief.approve"
    public static let answer = "chief.answer"
    public static let open = "chief.open"

    /// Chief is available when the host advertises every method used by the
    /// classic Home and conversation screens. Stop is the header action, and
    /// approve/answer back the interactive cards; exposing a partial host
    /// would present controls that can only fail at runtime.
    public static func isAvailable(in capabilities: Set<String>) -> Bool {
        Set([
            conversations,
            read,
            markRead,
            send,
            stop,
            approve,
            answer,
        ]).isSubset(of: capabilities)
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
public struct MobileChiefWork: Codable, Equatable, Sendable {
    public let session: String
    public let host: String?
    public let title: String
    public let status: String
    public let preview: String?

    public init(
        session: String,
        host: String? = nil,
        title: String,
        status: String,
        preview: String? = nil
    ) {
        self.session = session
        self.host = host
        self.title = title
        self.status = status
        self.preview = preview
    }
}

public struct MobileChiefApproval: Codable, Equatable, Sendable {
    public let request: String
    public let prompt: String
    public let options: [String]
    public let decided: String?

    public init(request: String, prompt: String, options: [String], decided: String? = nil) {
        self.request = request
        self.prompt = prompt
        self.options = options
        self.decided = decided
    }
}

/// Chief questions use the shared harness-neutral question model on the wire.
/// Keep a Chief-specific spelling at this API boundary so callers do not need
/// to know which shared package owns the representation.
public typealias MobileChiefQuestion = AgentQuestion

/// A structured payload for one non-text Chief part. Unknown kinds decode
/// safely with only their `kind`, allowing newer Mac builds to coexist with
/// older phones while the legacy `parts` kind list remains available.
public struct MobileChiefPart: Codable, Equatable, Sendable {
    public let kind: String
    public let work: MobileChiefWork?
    public let approval: MobileChiefApproval?
    public let question: MobileChiefQuestion?

    public init(
        kind: String,
        work: MobileChiefWork? = nil,
        approval: MobileChiefApproval? = nil,
        question: MobileChiefQuestion? = nil
    ) {
        self.kind = kind
        self.work = work
        self.approval = approval
        self.question = question
    }
}

public struct MobileChiefMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let seq: UInt64
    public let authorID: String
    public let author: String
    public let authorKind: String
    public let text: String
    public let at: Date
    /// Part kinds (`text`, `work`, `approval`, `question`, …). Kept for
    /// backwards compatibility with clients that only render plain text.
    public let parts: [String]
    /// Structured work, approval and question parts. Older Mac builds omit
    /// this field; those messages decode with an empty array.
    public let partPayloads: [MobileChiefPart]
    public let threadRoot: String?
    public let clientMessageID: String?

    public init(
        id: String,
        seq: UInt64,
        authorID: String,
        author: String,
        authorKind: String,
        text: String,
        at: Date,
        parts: [String] = [],
        partPayloads: [MobileChiefPart] = [],
        threadRoot: String? = nil,
        clientMessageID: String? = nil
    ) {
        self.id = id
        self.seq = seq
        self.authorID = authorID
        self.author = author
        self.authorKind = authorKind
        self.text = text
        self.at = at
        self.parts = parts
        self.partPayloads = partPayloads
        self.threadRoot = threadRoot
        self.clientMessageID = clientMessageID
    }

    private enum CodingKeys: String, CodingKey {
        case id, seq, authorID = "author_id", author, authorKind = "author_kind"
        case text, at, parts, partPayloads = "part_payloads"
        case threadRoot = "thread_root", clientMessageID = "client_message_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        seq = try c.decode(UInt64.self, forKey: .seq)
        authorID = try c.decode(String.self, forKey: .authorID)
        author = try c.decode(String.self, forKey: .author)
        authorKind = try c.decode(String.self, forKey: .authorKind)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Date.self, forKey: .at)
        parts = try c.decodeIfPresent([String].self, forKey: .parts) ?? []
        partPayloads = try c.decodeIfPresent([MobileChiefPart].self, forKey: .partPayloads) ?? []
        threadRoot = try c.decodeIfPresent(String.self, forKey: .threadRoot)
        clientMessageID = try c.decodeIfPresent(String.self, forKey: .clientMessageID)
    }
}

/// `chief.read` result. Messages are ordered oldest to newest by the Mac.
public struct MobileChiefReadResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let working: Bool
    public let messages: [MobileChiefMessage]
    /// The Mac owner's read cursor, when the host supports read-state fields.
    /// Older hosts omit these fields; callers then fall back to a conservative
    /// zero cursor rather than treating the transcript head as read.
    public let lastReadSeq: UInt64?
    public let unreadCount: Int?
    public let headSeq: UInt64?
    /// Opaque owner change cursor. Older hosts omit this field.
    public let changeCursor: String?
    /// True when another page exists before the oldest returned message.
    /// Older hosts omit this field and therefore remain a bounded, newest-page
    /// reader to older phones.
    public let hasMore: Bool

    public init(
        conversation: String,
        working: Bool = false,
        messages: [MobileChiefMessage] = [],
        hasMore: Bool = false,
        lastReadSeq: UInt64? = nil,
        unreadCount: Int? = nil,
        headSeq: UInt64? = nil,
        changeCursor: String? = nil
    ) {
        self.conversation = conversation
        self.working = working
        self.messages = messages
        self.hasMore = hasMore
        self.lastReadSeq = lastReadSeq
        self.unreadCount = unreadCount
        self.headSeq = headSeq
        self.changeCursor = changeCursor
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, working, messages, hasMore = "has_more"
        case lastReadSeq = "last_read_seq", unreadCount = "unread_count", headSeq = "head_seq"
        case changeCursor = "change_cursor"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(String.self, forKey: .conversation)
        working = try c.decodeIfPresent(Bool.self, forKey: .working) ?? false
        messages = try c.decodeIfPresent([MobileChiefMessage].self, forKey: .messages) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        lastReadSeq = try c.decodeIfPresent(UInt64.self, forKey: .lastReadSeq)
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount)
        headSeq = try c.decodeIfPresent(UInt64.self, forKey: .headSeq)
        changeCursor = try c.decodeIfPresent(String.self, forKey: .changeCursor)
    }
}

/// `chief.send` result.
public struct MobileChiefSendResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let messageID: String?
    public let clientMessageID: String?
    public let queued: Bool

    public init(
        conversation: String,
        messageID: String? = nil,
        clientMessageID: String? = nil,
        queued: Bool = false
    ) {
        self.conversation = conversation
        self.messageID = messageID
        self.clientMessageID = clientMessageID
        self.queued = queued
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, messageID = "message_id", clientMessageID = "client_message_id", queued
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
/// The transcript read supports an event-backed wait from newer Mac hosts.
/// Older hosts reject the optional wait fields as invalid parameters, which
/// surfaces through the normal reconnect path instead of silently mutating a
/// regular read.
public actor MobileChiefClient {
    /// `chief.read(wait_for_change:)` is a long poll backed by the Mac Chief
    /// event stream. Give it its own deadline so an idle conversation does not
    /// inherit the short foreground RPC deadline; cancellation still tears
    /// down the request when the conversation view disappears.
    private static let readWaitTimeoutNanoseconds: UInt64 = 600 * 1_000_000_000

    private let client: MobileCoreRPCClient
    private let coding = ChatWireCoding()

    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    public func status() async throws -> MobileChiefStatus {
        try await request("chief.status", params: [:], as: MobileChiefStatus.self)
    }

    public func conversations() async throws -> [MobileChiefConversation] {
        let snapshot = try await conversationsSnapshot()
        return snapshot.conversations
    }

    /// Reads the Home conversation snapshot and its opaque owner change cursor.
    /// With `waitForChange`, the Mac holds the request until the inbox or any
    /// conversation row changes, so Home can stay fresh without a timer.
    public func conversationsSnapshot(
        afterCursor: String? = nil,
        waitForChange: Bool = false
    ) async throws -> MobileChiefConversationSnapshot {
        var params: [String: Any] = [:]
        if let afterCursor { params["after_cursor"] = afterCursor }
        if waitForChange { params["wait_for_change"] = true }
        return try await request(
            "chief.conversations",
            params: params,
            timeoutNanoseconds: waitForChange ? Self.readWaitTimeoutNanoseconds : nil,
            as: MobileChiefConversationSnapshot.self
        )
    }

    public func read(
        conversation: String? = nil,
        beforeSeq: UInt64? = nil,
        limit: Int = 20,
        afterSeq: UInt64? = nil,
        afterCursor: String? = nil,
        waitForChange: Bool = false
    ) async throws -> MobileChiefReadResult {
        var params: [String: Any] = ["limit": max(1, min(limit, 200))]
        if let conversation { params["conversation"] = conversation }
        if let beforeSeq { params["before_seq"] = beforeSeq }
        if let afterSeq { params["after_seq"] = afterSeq }
        if let afterCursor { params["after_cursor"] = afterCursor }
        if waitForChange { params["wait_for_change"] = true }
        return try await request(
            "chief.read",
            params: params,
            timeoutNanoseconds: waitForChange ? Self.readWaitTimeoutNanoseconds : nil,
            as: MobileChiefReadResult.self
        )
    }

    public func markRead(conversation: String? = nil, upToSeq: UInt64) async throws -> MobileChiefMarkReadResult {
        var params: [String: Any] = ["up_to_seq": upToSeq]
        if let conversation { params["conversation"] = conversation }
        return try await request("chief.mark_read", params: params, as: MobileChiefMarkReadResult.self)
    }

    public func send(
        _ text: String,
        conversation: String? = nil,
        from: String? = nil,
        startTurn: Bool = true,
        clientMessageID: String? = nil
    ) async throws -> MobileChiefSendResult {
        var params: [String: Any] = ["text": text, "start_turn": startTurn]
        if let conversation { params["conversation"] = conversation }
        if let from { params["from"] = from }
        if let clientMessageID { params["client_message_id"] = clientMessageID }
        return try await request("chief.send", params: params, as: MobileChiefSendResult.self)
    }

    public func stop(conversation: String? = nil) async throws -> MobileChiefStopResult {
        var params: [String: Any] = [:]
        if let conversation { params["conversation"] = conversation }
        return try await request("chief.stop", params: params, as: MobileChiefStopResult.self)
    }

    public func approve(
        conversation: String? = nil,
        request requestID: String? = nil,
        choice: String
    ) async throws -> MobileChiefApprovalResult {
        var params: [String: Any] = ["choice": choice]
        if let conversation { params["conversation"] = conversation }
        if let requestID { params["request"] = requestID }
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

    private func request<T: Decodable>(
        _ method: String,
        params: [String: Any],
        timeoutNanoseconds: UInt64? = nil,
        as type: T.Type
    ) async throws -> T {
        let request = try MobileCoreRPCClient.requestData(method: method, params: params)
        let result = try await client.sendRequest(request, timeoutNanoseconds: timeoutNanoseconds)
        return try coding.decode(type, from: result)
    }
}

public struct MobileChiefConversationSnapshot: Codable, Equatable, Sendable {
    public let conversations: [MobileChiefConversation]
    public let changeCursor: String?

    public init(conversations: [MobileChiefConversation] = [], changeCursor: String? = nil) {
        self.conversations = conversations
        self.changeCursor = changeCursor
    }

    private enum CodingKeys: String, CodingKey {
        case conversations
        case changeCursor = "change_cursor"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([MobileChiefConversation].self, forKey: .conversations) ?? []
        changeCursor = try c.decodeIfPresent(String.self, forKey: .changeCursor)
    }
}

public struct MobileChiefStopResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let stopped: Bool
}

public struct MobileChiefMarkReadResult: Codable, Equatable, Sendable {
    public let conversation: String
    public let upToSeq: UInt64
    public let marked: Bool

    public init(conversation: String, upToSeq: UInt64, marked: Bool = true) {
        self.conversation = conversation
        self.upToSeq = upToSeq
        self.marked = marked
    }

    private enum CodingKeys: String, CodingKey {
        case conversation
        case upToSeq = "up_to_seq"
        case marked
    }
}

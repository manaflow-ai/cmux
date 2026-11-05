import Foundation

/// Rust/acpmux-backed mobile chat relay commands. The Swift host only carries
/// the typed request to the daemon; chat/session policy lives in cmux-tui.
public struct MobileChatSessionsRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "mobile-chat-sessions"
    public var machineID: String?
    public var limit: UInt64?
    public var cursor: String?
    public var status: String?
    public init(machineID: String? = nil, limit: UInt64? = nil, cursor: String? = nil, status: String? = nil) {
        self.machineID = machineID; self.limit = limit; self.cursor = cursor; self.status = status
    }
}

public struct MobileChatHistoryRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "mobile-chat-history"
    public var sessionID: String
    public var afterSeq: UInt64?
    public var beforeSeq: UInt64?
    public var limit: UInt64?
    public var kinds: [String]?
    public init(sessionID: String, afterSeq: UInt64? = nil, beforeSeq: UInt64? = nil,
                limit: UInt64? = nil, kinds: [String]? = nil) {
        self.sessionID = sessionID; self.afterSeq = afterSeq; self.beforeSeq = beforeSeq
        self.limit = limit; self.kinds = kinds
    }
}

public struct MobileChatSendRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "mobile-chat-send"
    public var sessionID: String
    public var text: String
    public var promptID: String
    public init(sessionID: String, text: String, promptID: String) {
        self.sessionID = sessionID; self.text = text; self.promptID = promptID
    }
}

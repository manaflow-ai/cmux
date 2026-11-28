import Foundation

/// `terminal-clipboard-subscribe` (capability `terminal-clipboard-read-v1`,
/// cmux-tui/spec/commands.md "Terminal clipboard reads"): the exact public
/// terminal ids (`term_…`, at most 256) whose OSC 52 reads this connection
/// answers. A new call replaces the previous set. Only a verified-app
/// frontend connection may send it; others get `origin.forbidden`.
public struct TerminalClipboardSubscribeRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var clipboardReadReady: Bool
        enum CodingKeys: String, CodingKey { case clipboardReadReady = "clipboard_read_ready" }
    }
    public static let command = "terminal-clipboard-subscribe"
    public var terminalIDs: [String]

    enum CodingKeys: String, CodingKey { case terminalIDs = "terminal_ids" }

    public init(terminalIDs: [String]) {
        self.terminalIDs = terminalIDs
    }
}

/// `terminal-clipboard-reply`: answers one `terminal-clipboard-read`. A
/// string `text` grants it; nil (sent as an absent field) refuses it.
public struct TerminalClipboardReplyRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var accepted: Bool
        public var granted: Bool
    }
    public static let command = "terminal-clipboard-reply"
    public var requestID: String
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case text
    }

    public init(requestID: String, text: String?) {
        self.requestID = requestID
        self.text = text
    }
}

import Foundation

/// The pane's reply in place to another agent's message (IncomingMessageCard.tsx, direct.ts
/// `reply`) goes out as a cmux agent message from the chat the pane shows, as that chat's agent
/// would send it with `cmux agent message --reply-to`.
///
/// The page sends `_acpmux/app_reply {sessionId, to, replyTo, threadId, text, replyId}` through
/// the relay, which takes it only for the pane's own chat (``AcpmuxPaneMethods/sessionScoped``),
/// with exactly those params and on a gesture. acpmux checks it (acpmux `server/app_reply.rs`:
/// a chat this connection shows got message `replyTo` from chat `to` in thread `threadId`) and
/// answers it signed, with the chat's own name and an idempotency key; it prompts nothing. The
/// relay does not pass that answer to the page (``AcpmuxRequestIds/toPage(_:)``): only when it is
/// for the very chat the frame named, still in the pane's scope, it hands the reply to ``Send``,
/// which the App wires to this Mac's cmux daemon (DaemonService `sendAgentReply`). The app's own
/// proven connection is the only one that may mint a launch credential; it mints one for that
/// chat and sends `agent.message.send` as it. The daemon checks the reply again (the parent, its
/// thread, the chat's part in it) and delivers it to the parent's sender. The page gets the
/// stored message's id and thread only. A chat on another machine has no ``Send`` here: refused.
public nonisolated struct AgentPaneAgentReply: Equatable, Sendable {
    /// The ACP session the reply is sent as (the pane's chat).
    public var session: String
    /// The name acpmux signed the reply with (the chat's own), nil when it gave none.
    public var senderName: String?
    /// The agent message it answers, and that message's thread.
    public var replyTo: String
    public var threadId: String
    public var text: String
    /// The key the daemon stores it once under (acpmux's, from the chat and the page's `replyId`).
    public var idempotencyKey: String

    public init(session: String, senderName: String?, replyTo: String, threadId: String, text: String, idempotencyKey: String) {
        self.session = session
        self.senderName = senderName
        self.replyTo = replyTo
        self.threadId = threadId
        self.text = text
        self.idempotencyKey = idempotencyKey
    }

    /// What the daemon stored.
    public struct Stored: Equatable, Sendable {
        public var id: String
        public var threadId: String

        public init(id: String, threadId: String) {
            self.id = id
            self.threadId = threadId
        }
    }

    /// Why a reply did not leave.
    public enum Failure: Error, Equatable, Sendable {
        /// No daemon takes it here (no connection, or a chat on another machine).
        case unavailable
    }

    /// Mints a credential for ``session`` and sends the reply as it; throws the daemon's refusal.
    public typealias Send = @MainActor @Sendable (AgentPaneAgentReply) async throws -> Stored

    /// The relay method whose reply the host completes itself.
    static let method = "_acpmux/app_reply"
    /// Longest reply text the host sends on (acpmux's and the daemon's bound).
    static let maximumText = 32 * 1024
    /// Longest id, address, key or name field.
    static let maximumField = 256

    /// acpmux's answer to the frame that named chat `subject`, as the reply to send: nil unless it
    /// is a signed reply from `acp:<subject>`, a chat still in the pane's scope, in the shape
    /// acpmux writes.
    static func signed(_ result: [String: Any]?, subject: String?, sessions: AcpmuxPaneSessions) -> AgentPaneAgentReply? {
        guard let subject, sessions.contains(subject), let reply = result?["reply"] as? [String: Any] else { return nil }
        // Rust char::is_control (acpmux, the daemon) is category Cc only: format characters pass.
        func field(_ key: String, _ limit: Int = maximumField) -> String? {
            guard let value = reply[key] as? String, !value.isEmpty, value.utf8.count <= limit,
                  !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) else { return nil }
            return value
        }
        guard field("from") == "acp:\(subject)", let replyTo = field("replyTo"), let threadId = field("threadId"),
              let text = field("text", maximumText), let key = field("idempotencyKey") else { return nil }
        var name: String?
        if let raw = reply["fromName"], !(raw is NSNull) {
            guard let signedName = field("fromName") else { return nil }
            name = signedName
        }
        return AgentPaneAgentReply(session: subject, senderName: name, replyTo: replyTo, threadId: threadId, text: text, idempotencyKey: key)
    }

    /// What the socket does with acpmux's answer to the frame that named `subject`.
    enum Step: Sendable {
        /// This frame to the page (nil: none encodes).
        case answer(String?)
        /// Send this reply, then answer the page.
        case send(AgentPaneAgentReply)
    }

    /// The step for acpmux's `object` to page request `pageID` (raw JSON): an error goes to the page
    /// as acpmux wrote it; a signed reply is sent when the pane can send one, else refused. Never
    /// acpmux's signed reply itself.
    static func step(_ object: [String: Any], pageID: String, subject: String?, sessions: AcpmuxPaneSessions, canSend: Bool) -> Step {
        if let error = object["error"] { return .answer(frame(pageID: pageID, ["error": error])) }
        guard let reply = signed(object["result"] as? [String: Any], subject: subject, sessions: sessions) else {
            return .answer(frame(pageID: pageID, ["error": refusal("reply.refused", "the reply does not answer a message this chat got")]))
        }
        guard canSend else {
            return .answer(frame(pageID: pageID, ["error": refusal("reply.daemon_unavailable", "no cmux daemon on this Mac takes the reply")]))
        }
        return .send(reply)
    }

    /// `reply` sent with `send`, as the page's answer to request `pageID`: what the daemon stored,
    /// or a refusal (never the daemon's words, which may name other chats).
    static func sent(_ reply: AgentPaneAgentReply, pageID: String, send: Send) async -> String? {
        do {
            let stored = try await send(reply)
            return frame(pageID: pageID, ["result": ["agentMessage": ["id": stored.id, "threadId": stored.threadId]]])
        } catch Failure.unavailable {
            return frame(pageID: pageID, ["error": refusal("reply.daemon_unavailable", "no cmux daemon on this Mac takes the reply")])
        } catch {
            return frame(pageID: pageID, ["error": refusal("reply.daemon_refused", "the cmux daemon did not take the reply")])
        }
    }

    private static func frame(pageID: String, _ body: [String: Any]) -> String? {
        var frame = body
        frame["jsonrpc"] = "2.0"
        frame["id"] = AcpmuxRequestIds.value(pageID) ?? NSNull()
        return AcpmuxRequestIds.encode(frame)
    }

    private static func refusal(_ reason: String, _ message: String) -> [String: Any] {
        ["code": -32000, "message": message, "data": ["reason": reason]]
    }
}

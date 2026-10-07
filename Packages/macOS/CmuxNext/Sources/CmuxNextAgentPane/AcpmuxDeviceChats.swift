import Foundation

/// One chat of the daemon's device-wide index (`_acpmux/chats`, ALL-CHATS-ON-DEVICE): a Claude
/// Code, Codex or other harness conversation on this Mac, whether or not acpmux ran it. Titles and
/// folders are user data; only the local unix socket serves them.
public nonisolated struct AcpmuxDeviceChat: Hashable, Sendable, Identifiable {
    /// `<harness>:<session id>`, the key `_acpmux/chat_open` takes.
    public var id: String
    /// The index's harness id: `claude-code`, `codex`, `opencode`, ...
    public var harness: String
    /// The harness's own session id, the one an adopt names.
    public var sessionID: String
    public var title: String?
    /// The recorded folder; nil when the harness recorded none.
    public var cwd: String?
    /// Milliseconds since 1970.
    public var updatedMs: Double
    public var messageCount: Int?
    /// How it opens again: `adopt` (Claude Code and Codex through acpmux), `argv` (a terminal
    /// command) or `readOnly`.
    public var resume: String

    public init(id: String, harness: String, sessionID: String, title: String?, cwd: String?, updatedMs: Double,
                messageCount: Int? = nil, resume: String) {
        self.id = id
        self.harness = harness
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.updatedMs = updatedMs
        self.messageCount = messageCount
        self.resume = resume
    }

    /// The chats of a `_acpmux/chats` result, in its order (newest first). Archived chats and
    /// rows without a key or session id are left out.
    public static func page(_ result: [String: Any]) -> [AcpmuxDeviceChat] {
        (result["chats"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { chat in
            guard let key = chat["key"] as? String, let harness = chat["harness"] as? String,
                  let session = chat["sessionId"] as? String, !session.isEmpty,
                  chat["archived"] as? Bool != true else { return nil }
            let text = { (name: String) in (chat[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return AcpmuxDeviceChat(
                id: key, harness: harness, sessionID: session, title: text("title"), cwd: text("cwd"),
                updatedMs: (chat["updatedMs"] as? NSNumber)?.doubleValue ?? 0,
                messageCount: (chat["messageCount"] as? NSNumber)?.intValue,
                resume: (chat["resume"] as? [String: Any])?["kind"] as? String ?? "readOnly")
        }
    }
}

/// The daemon's device-wide chat index over the unix socket.
public nonisolated enum AcpmuxDeviceChats {
    /// `_acpmux/chats {limit}`: the newest chats on this device. Nil when the daemon cannot
    /// answer (no socket, an older daemon, the index still scanning or turned off).
    @concurrent public static func newest(socketPath: String, limit: Int,
                                          deadline: Duration = .seconds(2)) async -> [AcpmuxDeviceChat]? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/chats",
                                                               params: ["limit": limit], deadline: deadline),
              result["ready"] as? Bool == true, result["enabled"] as? Bool != false else { return nil }
        return AcpmuxDeviceChat.page(result)
    }
}

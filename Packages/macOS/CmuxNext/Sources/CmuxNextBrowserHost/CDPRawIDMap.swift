import CmuxNextBrowser
import Foundation

/// The CDP id remap of one relayed CEF tab. The shim takes raw sends only
/// with ids from 2^30 to Int32.max (`cmux_cef_shim.h`, `CEFDevToolsRawMessage`),
/// and the host's ids are small: each host command gets the next raw id, and
/// the reply gets the host's id back. Events (no top-level "id") pass through
/// unchanged; "sessionId" and every other byte stay as they were. Ids are
/// found by a scan of the top-level keys, not a full parse.
public nonisolated struct CDPRawIDMap: Sendable {
    /// Raw id -> host id of commands sent and not answered yet.
    public private(set) var pending: [Int: Int] = [:]
    /// The "sessionId" of each pending command (nil: browser session), to
    /// answer it when the relay closes. Only the id and session are kept.
    private var sessions: [Int: String?] = [:]
    private var next: Int

    /// `firstRawID` continues an earlier relay's ids for the same tab.
    public init(firstRawID: Int? = nil) {
        next = firstRawID.flatMap { CEFDevToolsRawMessage.isRawID($0) ? $0 : nil } ?? CEFDevToolsRawMessage.firstRawID
    }

    /// The raw id the next command gets.
    public var nextRawID: Int { next }

    /// The host's command with a raw id, or nil when it has no single
    /// integer top-level "id" (the shim would refuse it).
    public mutating func outbound(_ message: String) -> (message: String, rawID: Int, hostID: Int)? {
        guard let hostID = CEFDevToolsRawMessage.topLevelID(in: message) else { return nil }
        let raw = allocate()
        guard let rewritten = CEFDevToolsRawMessage.replacingTopLevelID(in: message, with: raw) else { return nil }
        pending[raw] = hostID
        sessions[raw] = Self.sessionID(of: message)
        return (rewritten, raw, hostID)
    }

    /// Drops a command the shim did not send.
    public mutating func forget(rawID: Int) {
        pending[rawID] = nil
        sessions[rawID] = nil
    }

    /// The host's commands still waiting for a reply (host id and
    /// "sessionId"), oldest first; the map forgets them (the relay closed:
    /// each gets an error reply instead).
    public mutating func drainPending() -> [(hostID: Int, sessionID: String?)] {
        let waiting = pending.sorted { $0.key < $1.key }.map { (hostID: $0.value, sessionID: sessions[$0.key] ?? nil) }
        pending = [:]
        sessions = [:]
        return waiting
    }

    /// The top-level "sessionId" of a host command; parsed only when the
    /// command names one (most go to the page session's own flat session).
    static func sessionID(of message: String) -> String? {
        guard message.contains("\"sessionId\""),
              let object = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] else { return nil }
        return object["sessionId"] as? String
    }

    /// A message from the browser for the host: an event as it is, a reply
    /// to one of the host's commands with the host's id, nil for anything
    /// else (a reply the host never asked for).
    public mutating func inbound(_ message: String) -> String? {
        guard let id = CEFDevToolsRawMessage.topLevelID(in: message) else { return message }
        guard CEFDevToolsRawMessage.isRawID(id), let hostID = pending.removeValue(forKey: id) else { return nil }
        sessions[id] = nil
        return CEFDevToolsRawMessage.replacingTopLevelID(in: message, with: hostID)
    }

    private mutating func allocate() -> Int {
        var id = next
        while pending[id] != nil { id = Self.after(id) }
        next = Self.after(id)
        return id
    }

    private static func after(_ id: Int) -> Int {
        id >= Int(Int32.max) ? CEFDevToolsRawMessage.firstRawID : id + 1
    }

    /// A CDP error reply to host command `message` (same id and
    /// "sessionId"), for a command the app could not relay.
    public static func errorReply(to message: String, text: String) -> String? {
        guard let id = CEFDevToolsRawMessage.topLevelID(in: message) else { return nil }
        return errorReply(hostID: id, sessionID: sessionID(of: message), text: text)
    }

    /// A CDP error reply with host id `hostID` in session `sessionID`.
    public static func errorReply(hostID: Int, sessionID: String?, text: String) -> String? {
        var reply: [String: Any] = ["id": hostID, "error": ["code": -32000, "message": text]]
        if let sessionID { reply["sessionId"] = sessionID }
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

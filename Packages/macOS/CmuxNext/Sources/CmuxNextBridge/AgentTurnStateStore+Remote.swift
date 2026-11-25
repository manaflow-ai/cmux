public import CmuxNextDaemon
import Foundation

/// The names of chats whose acpmux runs on another machine (cmux#55668). This Mac's watch never lists a Cloud
/// machine's chats, so a Cloud chat's tab read its workspace's `workspace-N` and the workspace never took the
/// chat's title. The chat's page reads its summary over its remote wire (`RemoteAcpmuxWire`, the attach and each
/// `_acpmux/session_changed`), and the app notes it here: the same name readers (``title(for:)``,
/// ``generatedTitle(for:)``, ``sessionName(for:)``, ``displayName(for:)``) then answer for it as for a local chat,
/// so the tab strip and workspace auto-naming take one path for both.
///
/// Records are keyed by host and session (session ids are each daemon's own) and hold names only: a remote
/// chat's turn state stays its machine's (``isWorking(_:isChatMachine:)`` reads the acpmux peers' rows).
///
/// Another machine's summary is untrusted input. Only the name fields are read (``remoteFields``; never its icon,
/// whose inline image bytes this Mac would decode), each capped before parsing, and every name kept is plain text
/// (``plainName(_:)``): one line, no control or invisible characters (bidi overrides, zero-width), at most
/// ``remoteNameLimit`` characters.
extension AgentTurnStateStore {
    /// The most remote chats whose names are kept; the map starts again past it (a page notes its chat again on
    /// each attach and change).
    static let remoteLimit = 4096

    /// The key of `session` on `host` in ``remoteSessions``. A NUL never occurs in a session id, so it never
    /// collides with the ``awaited`` signal of a local session.
    static func remoteKey(host: String, session: String) -> String { host + "\u{0}" + session }

    /// The summary fields a remote chat's names are read from; any other is dropped.
    static let remoteFields = ["sessionId", "title", "titleSource", "lastPrompt", "name", "harness", "family", "displayName"]
    /// The most characters a field is read at, before parsing, and a kept name at.
    nonisolated static let remoteFieldLimit = 4096, remoteNameLimit = 200
    /// The most former names kept (acpmux keeps a few; the newest are the ones a workspace name matches).
    static let remoteFormerNamesKept = 8

    /// The name fields of `summary`, each capped (``remoteFieldLimit``); never its icon or anything else.
    static func remoteSummary(_ summary: [String: Any]) -> [String: Any] {
        var safe: [String: Any] = [:]
        for key in remoteFields {
            if let text = summary[key] as? String { safe[key] = String(text.prefix(remoteFieldLimit)) }
        }
        if let former = summary["formerNames"] as? [Any] {
            safe["formerNames"] = former.suffix(remoteFormerNamesKept).compactMap { ($0 as? String).map { String($0.prefix(remoteFieldLimit)) } }
        }
        return safe
    }

    /// `text` as plain one-line text: line breaks, tabs and control characters become one space, invisible format
    /// characters (bidi overrides and isolates, zero-width spaces) are dropped but the joiner emoji sequences use, and it
    /// is trimmed and capped at ``remoteNameLimit`` characters. Nil when nothing readable is left.
    public nonisolated static func plainName(_ text: String?) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        var spaced = true
        for scalar in text.unicodeScalars.prefix(remoteFieldLimit) {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                if !spaced { scalars.append(" ") }
                spaced = true
            case .format where scalar != "\u{200D}", .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(scalar)
                spaced = false
            }
        }
        let plain = String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(remoteNameLimit))
        return plain.isEmpty ? nil : plain
    }

    /// Whether `session` is a session id this Mac keys a remote record by: short, with no control character.
    static func isRemoteSessionID(_ session: String) -> Bool {
        !session.isEmpty && session.utf8.count <= 256 && !session.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// How many remote chats have names noted (tests).
    public var remoteRecordCount: Int { remoteSessions.count }

    /// Notes the names of the chat `summary` describes (an acpmux session summary) on machine `host` (the tab's
    /// `install:<id>`, ``AgentSessionRef/host``). Ignored for this Mac's own host and the mirrored ones: their
    /// watch owns those records. Writes only what changed.
    public func noteRemote(_ untrusted: [String: Any], host: String) {
        let summary = Self.remoteSummary(untrusted)
        guard let session = summary["sessionId"] as? String, Self.isRemoteSessionID(session), !host.isEmpty,
              host != localHost, !mirroredHosts.contains(host) else { return }
        let key = Self.remoteKey(host: host, session: session)
        let record: Session
        if let held = remoteSessions[key] {
            record = held
        } else {
            if remoteSessions.count >= Self.remoteLimit { remoteSessions.removeAll() }
            record = Session()
            remoteSessions[key] = record
            if let signal = awaited.removeValue(forKey: key) { signal.made &+= 1 }
        }
        let title = Self.plainName(AgentTurnStates.title(summary))
        let generatedTitle = Self.plainName(AgentTurnStates.title(summary, includingPrompt: false))
        let sessionName = Self.plainName(AgentTurnStates.sessionName(summary))
        // Its given name and former names only: a remote chat's icon is never read (``remoteSummary(_:)`` drops it).
        let identity = AgentSessionIdentity.of(summary: summary).map {
            AgentSessionIdentity(displayName: Self.plainName($0.displayName), formerNames: $0.formerNames.compactMap(Self.plainName))
        }.flatMap { $0 == AgentSessionIdentity() ? nil : $0 }
        if record.title != title { record.title = title }
        if record.generatedTitle != generatedTitle { record.generatedTitle = generatedTitle }
        if record.sessionName != sessionName { record.sessionName = sessionName }
        if record.identity != identity {
            record.identity = identity
            record.iconArt = nil
        }
    }

    /// The noted names of the chat `ref` shows when it runs on another machine; nil for this Mac's chats and
    /// before its page noted any, after observing that chat's own signal so the reader reads again once noted.
    func remote(_ ref: AgentSessionRef) -> Session? {
        guard let session = ref.session, ref.host != localHost, !mirroredHosts.contains(ref.host) else { return nil }
        let key = Self.remoteKey(host: ref.host, session: session)
        if let record = remoteSessions[key] { return record }
        let signal = awaited[key] ?? {
            let made = AgentTurnRecordSignal()
            awaited[key] = made
            return made
        }()
        _ = signal.made
        return nil
    }
}

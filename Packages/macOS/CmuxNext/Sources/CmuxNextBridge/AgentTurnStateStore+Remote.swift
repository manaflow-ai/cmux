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
extension AgentTurnStateStore {
    /// The most remote chats whose names are kept; the map starts again past it (a page notes its chat again on
    /// each attach and change).
    static let remoteLimit = 4096

    /// The key of `session` on `host` in ``remoteSessions``. A NUL never occurs in a session id, so it never
    /// collides with the ``awaited`` signal of a local session.
    static func remoteKey(host: String, session: String) -> String { host + "\u{0}" + session }

    /// How many remote chats have names noted (tests).
    public var remoteRecordCount: Int { remoteSessions.count }

    /// Notes the names of the chat `summary` describes (an acpmux session summary) on machine `host` (the tab's
    /// `install:<id>`, ``AgentSessionRef/host``). Ignored for this Mac's own host and the mirrored ones: their
    /// watch owns those records. Writes only what changed.
    public func noteRemote(_ summary: [String: Any], host: String) {
        guard let session = summary["sessionId"] as? String, !session.isEmpty, !host.isEmpty,
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
        let title = AgentTurnStates.title(summary)
        let generatedTitle = AgentTurnStates.title(summary, includingPrompt: false)
        let sessionName = AgentTurnStates.sessionName(summary)
        let identity = AgentSessionIdentity.of(summary: summary)
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

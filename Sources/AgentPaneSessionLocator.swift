import Foundation

/// Finds the agent session a terminal pane is running, from the agent's hook
/// session store.
///
/// Claude's store keeps an active-session pointer per surface, so a nested
/// `claude -p` run in the pane is never mistaken for the pane's session.
/// Codex's store has no pointer, so the newest entry bound to the surface wins.
struct AgentPaneSessionLocator: Sendable {
    struct Session: Equatable, Sendable {
        let sessionID: String
        let transcriptPath: String?
    }

    let agent: RestorableAgentKind
    let hookStoreURL: URL

    init(agent: RestorableAgentKind, hookStoreURL: URL? = nil) {
        self.agent = agent
        self.hookStoreURL = hookStoreURL ?? agent.hookStoreFileURL()
    }

    func session(surfaceID: UUID) -> Session? {
        guard let data = try? Data(contentsOf: hookStoreURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let sessions = (root["sessions"] as? [String: Any]) ?? [:]
        let surface = surfaceID.uuidString
        let sessionID: String?
        if let active = root["activeSessionsBySurface"] as? [String: Any] {
            sessionID = (active[surface] as? [String: Any])?["sessionId"] as? String
        } else {
            sessionID = sessions
                .compactMap { key, value -> (String, Double)? in
                    guard let record = value as? [String: Any],
                          (record["surfaceId"] as? String)?.caseInsensitiveCompare(surface) == .orderedSame else {
                        return nil
                    }
                    return (key, record["updatedAt"] as? Double ?? 0)
                }
                .max { $0.1 < $1.1 }?
                .0
        }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        let transcriptPath = ((sessions[sessionID] as? [String: Any])?["transcriptPath"] as? String)
            .flatMap { $0.hasPrefix("/") ? $0 : nil }
        return Session(sessionID: sessionID, transcriptPath: transcriptPath)
    }
}

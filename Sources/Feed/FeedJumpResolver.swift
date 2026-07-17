import Foundation

/// Resolves Feed workstream identifiers through the per-agent hook-session
/// stores written by `cmux <agent>-hook session-start`.
final class FeedJumpResolver: @unchecked Sendable {
    private let sessionsDirectory: URL

    init(
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
    ) {
        self.sessionsDirectory = sessionsDirectory
    }

    func parse(_ workstreamId: String) -> (agent: String, sessionId: String)? {
        guard let dash = workstreamId.firstIndex(of: "-") else { return nil }
        let agent = String(workstreamId[..<dash])
        let sessionId = String(workstreamId[workstreamId.index(after: dash)...])
        guard !agent.isEmpty, !sessionId.isEmpty else { return nil }
        return (agent, sessionId)
    }

    func lookup(agent: String, sessionId: String) -> FeedJumpTarget? {
        let file = sessionsDirectory
            .appendingPathComponent("\(agent)-hook-sessions.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Stores have a consistent shape: top-level `sessions` dict keyed
        // by sessionId. Tolerate older flat layouts too.
        let sessions: [String: Any]
        if let nested = root["sessions"] as? [String: Any] {
            sessions = nested
        } else {
            sessions = root
        }
        guard let entry = sessions[sessionId] as? [String: Any],
              let workspaceId = entry["workspaceId"] as? String,
              let surfaceId = entry["surfaceId"] as? String,
              !workspaceId.isEmpty, !surfaceId.isEmpty
        else { return nil }
        return FeedJumpTarget(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    func resolve(_ workstreamId: String) -> FeedJumpTarget? {
        guard let parsed = parse(workstreamId) else { return nil }
        return lookup(agent: parsed.agent, sessionId: parsed.sessionId)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func resolveOffMain(_ workstreamId: String) async -> FeedJumpTarget? {
        await Task.detached(priority: .userInitiated) { [self] in
            resolve(workstreamId)
        }.value
    }
}

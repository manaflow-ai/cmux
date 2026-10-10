import CmuxAgentChat
import CmuxMobileHost
import Foundation

extension AgentChatTranscriptService {
    /// The open Claude or Codex session in a pane, as Global Search indexes it.
    ///
    /// Only open sessions count: the registry's live record for the pane,
    /// never an ended one. Only the resolver's `boundedTranscriptPath` is read
    /// (the path the agent's hook recorded, or Claude's own project file for
    /// the session), so this never runs Codex's recursive fallback scan.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal panel's ID.
    /// - Returns: The session to index, or nil for panes without an open
    ///   session or a readable transcript.
    func globalSearchSource(surfaceID: UUID) -> AgentSessionSearchSource? {
        guard let record = registry.liveSession(surfaceID: surfaceID.uuidString) else { return nil }
        switch record.agentKind {
        case .claude, .codex:
            break
        case .other:
            return nil
        }
        guard let path = resolver.boundedTranscriptPath(for: record)
            ?? Self.liveCodexRolloutPath(for: record) else { return nil }
        return AgentSessionSearchSource(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcriptPath: path
        )
    }

    /// Codex's hooks don't report a transcript path, so the resolver's cheap
    /// lookup finds nothing for it. The live process keeps its rollout open,
    /// so read the path from its open files; without a pid, list only today's
    /// and yesterday's rollout directories (never the recursive scan).
    nonisolated static func liveCodexRolloutPath(
        for record: AgentChatSessionRecord,
        now: Date = Date(),
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) -> String? {
        guard record.agentKind == .codex else { return nil }
        let suffixes = Set([record.sessionID, record.hookStoreLookupSessionID].map { "-\($0.lowercased()).jsonl" })
        let matches: (String) -> Bool = { path in
            let lowered = path.lowercased()
            return suffixes.contains { lowered.hasSuffix($0) }
        }
        if let pid = record.pid,
           let open = AgentChatSessionRegistry.openCodexRolloutPaths(pid: pid).first(where: matches) {
            return open
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let directory = codexHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayOfMonth), isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            if let name = names.first(where: matches) {
                return directory.appendingPathComponent(name).path
            }
        }
        return nil
    }
}

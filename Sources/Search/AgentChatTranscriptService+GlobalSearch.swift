import CmuxAgentChat
import CmuxMobileHost
import Foundation

extension AgentChatTranscriptService {
    /// The open Claude or Codex session in a pane, as Global Search indexes it.
    ///
    /// Only open sessions count: the registry's live record for the pane,
    /// never an ended one. This runs on the main actor for every pane each
    /// time the palette opens, so it only reads the registry and the
    /// resolver's `boundedTranscriptPath` (the path the agent's hook
    /// recorded, or Claude's own project file for the session). A Codex
    /// session without a recorded path carries a `CodexRolloutLookup`
    /// instead, which `AgentSessionSearchTranscripts` resolves off the main
    /// actor; this never runs Codex's recursive fallback scan.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal panel's ID.
    /// - Returns: The session to index, or nil for panes without an open
    ///   session or, for Claude, a readable transcript.
    func globalSearchSource(surfaceID: UUID) -> AgentSessionSearchSource? {
        guard let record = registry.liveSession(surfaceID: surfaceID.uuidString) else { return nil }
        let transcript: AgentSessionSearchSource.Transcript
        switch record.agentKind {
        case .claude:
            guard let path = resolver.boundedTranscriptPath(for: record) else { return nil }
            transcript = .path(path)
        case .codex:
            if let path = resolver.boundedTranscriptPath(for: record) {
                transcript = .path(path)
            } else {
                transcript = .codexRollout(CodexRolloutLookup(record: record, codexHome: resolver.codexConfigRoot))
            }
        case .other:
            return nil
        }
        return AgentSessionSearchSource(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcript: transcript
        )
    }
}

/// How to find a live Codex session's rollout file. Codex's hooks don't
/// report a transcript path, so the resolver's cheap lookup finds nothing
/// for it.
///
/// `livePath` does blocking work (libproc and a directory listing) and runs
/// on `AgentSessionSearchTranscripts`' read queue, never on the main actor.
struct CodexRolloutLookup: Sendable, Equatable {
    /// Session IDs the rollout's file name may end with.
    let sessionIDs: [String]
    let pid: Int?
    /// `$CODEX_HOME` or `~/.codex`, as the transcript resolver has it.
    let codexHome: URL

    init(sessionIDs: [String], pid: Int?, codexHome: URL) {
        self.sessionIDs = sessionIDs
        self.pid = pid
        self.codexHome = codexHome
    }

    init(record: AgentChatSessionRecord, codexHome: URL) {
        self.init(
            sessionIDs: [record.sessionID, record.hookStoreLookupSessionID],
            pid: record.pid,
            codexHome: codexHome
        )
    }

    /// The live process keeps its rollout open, so read the path from its
    /// open files; without a pid, list only today's and yesterday's rollout
    /// directories (never the recursive scan). Once found, the reader keeps
    /// the path while the file exists, so the date window only matters for
    /// the first lookup.
    func livePath(now: Date = Date()) -> String? {
        let suffixes = Set(sessionIDs.map { "-\($0.lowercased()).jsonl" })
        let matches: (String) -> Bool = { path in
            let lowered = path.lowercased()
            return suffixes.contains { lowered.hasSuffix($0) }
        }
        if let pid,
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

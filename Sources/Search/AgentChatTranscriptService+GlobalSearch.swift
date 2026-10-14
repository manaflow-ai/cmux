import CmuxAgentChat
import CmuxMobileHost
import Foundation

extension AgentChatTranscriptService {
    /// The open Claude or Codex session in a pane, as Global Search indexes it.
    ///
    /// Only open sessions count: the registry's live record for the pane,
    /// never an ended one. The main-actor step only snapshots the in-memory
    /// binding. Transcript paths, including the cheap recorded-path check,
    /// are resolved by `AgentSessionSearchTranscripts` off the main actor.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal panel's ID.
    /// - Returns: The session to index, or nil for panes without an open
    ///   session or, for Claude, a readable transcript.
    func globalSearchSource(surfaceID: UUID) -> AgentSessionSearchSource? {
        guard let record = registry.liveSessionSnapshot(surfaceID: surfaceID.uuidString) else { return nil }
        guard record.agentKind == .claude || record.agentKind == .codex else { return nil }
        return AgentSessionSearchSource(
            sessionID: record.sessionID,
            agentKind: record.agentKind,
            transcript: .lookup(AgentSessionTranscriptLookup(record: record, resolver: resolver))
        )
    }
}

/// Resolves a live session's transcript without doing filesystem work on the
/// main actor. The resolver is a value type, so the detached reader can own a
/// snapshot safely while the registry continues receiving hook updates.
struct AgentSessionTranscriptLookup: Sendable {
    let record: AgentChatSessionRecord
    let resolver: AgentChatTranscriptResolver

    init(record: AgentChatSessionRecord, resolver: AgentChatTranscriptResolver) {
        self.record = record
        self.resolver = resolver
    }

    /// Returns a recorded or conventional transcript path, using Codex's
    /// bounded recent-rollout lookup as the fallback.
    func path() -> String? {
        if let path = resolver.boundedTranscriptPath(for: record) {
            return path
        }
        guard record.agentKind == .codex else { return nil }
        return CodexRolloutLookup(record: record, codexHome: resolver.codexConfigRoot).livePath()
    }
}

extension ChatAgentKind {
    /// Localized agent label used by Global Search result rows.
    var globalSearchDisplayName: String {
        switch self {
        case .claude:
            return String(localized: "globalSearch.agent.claude", defaultValue: "Claude")
        case .codex:
            return String(localized: "agentSession.provider.codex", defaultValue: "Codex")
        case .other:
            return displayName
        }
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
        if let open = openProcessPath() {
            return open
        }
        let suffixes = Set(sessionIDs.map { "-\($0.lowercased()).jsonl" })
        for directory in rolloutDirectories(now: now) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            if let name = names.first(where: { name in
                let lowered = name.lowercased()
                return suffixes.contains { lowered.hasSuffix($0) }
            }) {
                return directory.appendingPathComponent(name).path
            }
        }
        return nil
    }

    /// Returns an open rollout path held by the live Codex process, when one
    /// can be found without scanning the sessions directories.
    func openProcessPath() -> String? {
        guard let pid else { return nil }
        let suffixes = Set(sessionIDs.map { "-\($0.lowercased()).jsonl" })
        return AgentChatSessionRegistry.openCodexRolloutPaths(pid: pid).first { path in
            let lowered = path.lowercased()
            return suffixes.contains { lowered.hasSuffix($0) }
        }
    }

    /// The bounded date window used for the first no-PID Codex lookup.
    func rolloutDirectories(now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return [0, -1].compactMap { dayOffset in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
            return codexHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayOfMonth), isDirectory: true)
        }
    }
}

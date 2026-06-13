import CmuxAgentChat
import Foundation

/// Resolves the transcript JSONL path for an agent session.
///
/// Preference order: the hook store's recorded `transcriptPath`, then the
/// agent-specific conventional location (claude: encoded-cwd project dir;
/// codex: rollout filename containing the session id).
struct AgentChatTranscriptResolver: Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter homeDirectory: Injectable home directory for tests.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        self.fileManager = FileManager.default
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(for record: AgentChatSessionRecord) -> String? {
        if let recorded = record.transcriptPath {
            let expanded = (recorded as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return expanded
            }
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex:
            return codexFallbackPath(sessionID: record.sessionID)
        case .other:
            return nil
        }
    }

    /// The newest Claude transcript in a working directory's project dir,
    /// with its session id (the filename stem).
    ///
    /// Used to adopt a Claude session cmux detected by terminal title but
    /// that never ran a hook (e.g. launched through a shell wrapper that
    /// bypasses cmux's hook injection), so we never learned its session id.
    /// The newest `.jsonl` in the cwd's project dir is the live conversation.
    ///
    /// - Parameter workingDirectory: The agent's working directory.
    /// - Returns: The session id and absolute transcript path, or `nil` when
    ///   the project dir has no transcripts.
    func newestClaudeTranscript(workingDirectory: String) -> (sessionID: String, path: String)? {
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(workingDirectory)
        let dir = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let newest = entries
            .filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate < rDate
            }
        guard let newest else { return nil }
        return (sessionID: newest.deletingPathExtension().lastPathComponent, path: newest.path)
    }

    private func claudeFallbackPath(record: AgentChatSessionRecord) -> String? {
        guard let cwd = record.workingDirectory else { return nil }
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let path = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent("\(record.sessionID).jsonl", isDirectory: false)
            .path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    /// Codex rollout files are named `rollout-<timestamp>-<session-uuid>.jsonl`
    /// under `~/.codex/sessions/YYYY/MM/DD/`; scan recent day directories for
    /// the session id.
    private func codexFallbackPath(sessionID: String) -> String? {
        let root = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = sessionID.lowercased()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.lowercased().contains(needle) {
                return url.path
            }
        }
        return nil
    }
}

import CmuxAgentChat
import CMUXAgentLaunch
import Foundation

/// Reads the per-agent hook session stores from the configured hook state directory
/// the `cmux hooks` CLI maintains, yielding terminal bindings and transcript
/// paths for agent sessions.
///
/// Mirrors `FeedJumpResolver.lookup`'s tolerant parsing (nested `sessions`
/// dict with a flat-layout fallback) but surfaces the additional fields the
/// chat service needs (`cwd`, `transcriptPath`, `pid`).
struct AgentChatHookSessionStore: Sendable {
    /// One hook-store entry's chat-relevant fields.
    struct Entry: Sendable {
        /// The agent's session identifier (the store key).
        let sessionID: String
        /// Owning cmux workspace UUID string.
        let workspaceID: String?
        /// Hosting cmux terminal surface UUID string.
        let surfaceID: String?
        /// The session's working directory.
        let workingDirectory: String?
        /// Absolute transcript JSONL path, when the hook recorded one.
        let transcriptPath: String?
        /// The agent process id, for liveness checks.
        let pid: Int?
        /// When the hook store last updated the record.
        let updatedAt: Date?
    }

    private let stateDirectories: [URL]

    /// Creates a store reader.
    ///
    /// - Parameters:
    ///   - homeDirectory: The home directory containing the legacy `.cmuxterm/` fallback.
    ///   - environment: The process environment carrying `CMUX_AGENT_HOOK_STATE_DIR`.
    init(
        homeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        legacyHomeDirectory: URL? = nil
    ) {
        stateDirectories = AgentHookStateLocation.resolveReadDirectoryURLs(
            environment: environment,
            applicationSupportDirectory: homeDirectory == nil ? applicationSupportDirectory : nil,
            bundleIdentifier: homeDirectory == nil ? bundleIdentifier : nil,
            legacyHomeDirectory: legacyHomeDirectory
                ?? homeDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Reads one agent's hook session store.
    ///
    /// - Parameter agentSource: The agent's `_source` name (`claude`,
    ///   `codex`, ...), which names the store file.
    /// - Returns: All entries, or empty when the store is absent/malformed.
    func entries(agentSource: String) -> [Entry] {
        var entriesBySessionID: [String: Entry] = [:]
        for stateDirectory in stateDirectories {
            let file = stateDirectory
                .appendingPathComponent("\(agentSource)-hook-sessions.json", isDirectory: false)
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let sessions = (root["sessions"] as? [String: Any]) ?? root
            for (key, value) in sessions {
                guard let entry = value as? [String: Any] else { continue }
                let updatedAt = (entry["updatedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
                let candidate = Entry(
                    sessionID: key,
                    workspaceID: Self.nonEmpty(entry["workspaceId"] as? String),
                    surfaceID: Self.nonEmpty(entry["surfaceId"] as? String),
                    workingDirectory: Self.nonEmpty(entry["cwd"] as? String),
                    transcriptPath: Self.nonEmpty(entry["transcriptPath"] as? String),
                    pid: entry["pid"] as? Int,
                    updatedAt: updatedAt
                )
                if let existing = entriesBySessionID[key],
                   (candidate.updatedAt ?? .distantPast) <= (existing.updatedAt ?? .distantPast) {
                    continue
                }
                entriesBySessionID[key] = candidate
            }
        }
        return Array(entriesBySessionID.values)
    }

    /// Reads one session's entry from one agent's store.
    ///
    /// - Parameters:
    ///   - agentSource: The agent's `_source` name.
    ///   - sessionID: The session to look up.
    /// - Returns: The entry, or `nil` when absent.
    func entry(agentSource: String, sessionID: String) -> Entry? {
        entries(agentSource: agentSource).first { $0.sessionID == sessionID }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

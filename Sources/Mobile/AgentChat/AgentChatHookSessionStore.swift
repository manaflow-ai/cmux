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

    private let stateLocation: AgentHookStateReaderLocation
    private let fileManager: FileManager

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
        legacyHomeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        stateLocation = AgentHookStateReaderLocation(
            environment: environment,
            applicationSupportDirectory: homeDirectory == nil ? applicationSupportDirectory : nil,
            bundleIdentifier: homeDirectory == nil ? bundleIdentifier : nil,
            legacyHomeDirectory: legacyHomeDirectory
                ?? homeDirectory
                ?? fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )
        self.fileManager = fileManager
    }

    /// Reads one agent's hook session store.
    ///
    /// - Parameter agentSource: The agent's `_source` name (`claude`,
    ///   `codex`, ...), which names the store file.
    /// - Returns: All entries, or empty when the store is absent/malformed.
    func entries(agentSource: String) -> [Entry] {
        guard let data = stateLocation.storeData(
            named: "\(agentSource)-hook-sessions.json",
            fileManager: fileManager
        ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let sessions = (root["sessions"] as? [String: Any]) ?? root
        return sessions.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            let updatedAt = (entry["updatedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
            return Entry(
                sessionID: key,
                workspaceID: Self.nonEmpty(entry["workspaceId"] as? String),
                surfaceID: Self.nonEmpty(entry["surfaceId"] as? String),
                workingDirectory: Self.nonEmpty(entry["cwd"] as? String),
                transcriptPath: Self.nonEmpty(entry["transcriptPath"] as? String),
                pid: entry["pid"] as? Int,
                updatedAt: updatedAt
            )
        }
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

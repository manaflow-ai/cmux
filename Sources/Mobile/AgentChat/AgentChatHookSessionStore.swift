import CmuxAgentChat
import Foundation

/// Reads the per-agent hook session stores (`~/.cmuxterm/<agent>-hook-sessions.json`)
/// the `cmux hooks` CLI maintains, yielding terminal bindings and transcript
/// paths for agent sessions.
///
/// Mirrors `FeedJumpResolver.lookup`'s tolerant parsing (nested `sessions`
/// dict with a flat-layout fallback) but surfaces the additional fields the
/// chat service needs (`cwd`, `transcriptPath`, `pid`).
struct AgentChatHookSessionStore: Sendable {
    static let maximumSeedRecords = 512
    static let maximumSeedBytes: Int64 = 16 * 1_024 * 1_024

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

    private let homeDirectory: URL
    private let environment: [String: String]

    /// Creates a store reader.
    ///
    /// - Parameter homeDirectory: The home directory containing
    ///   `.cmuxterm/`; injectable for tests.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// Reads active sessions plus bounded recent history from one hook store.
    ///
    /// - Parameter agentSource: The agent's `_source` name (`claude`,
    ///   `codex`, ...), which names the store file.
    /// - Returns: The bounded seed entries, or empty when the store is absent/malformed.
    func entries(agentSource: String) -> [Entry] {
        guard let file = AgentHookSessionRegistryReader.legacyURL(
            provider: agentSource,
            homeDirectory: homeDirectory,
            environment: environment
        ),
              let records = AgentHookSessionRegistryReader.recentRecordData(
                  provider: agentSource,
                  legacyURL: file,
                  environment: environment,
                  maximumRecords: Self.maximumSeedRecords,
                  maximumBytes: Self.maximumSeedBytes
              ) else {
            return []
        }
        return records.compactMap { record in
            Self.entry(sessionID: record.sessionID, data: record.data)
        }
    }

    /// Reads one session's entry from one agent's store.
    ///
    /// - Parameters:
    ///   - agentSource: The agent's `_source` name.
    ///   - sessionID: The session to look up.
    /// - Returns: The entry, or `nil` when absent.
    func entry(agentSource: String, sessionID: String) -> Entry? {
        guard let file = AgentHookSessionRegistryReader.legacyURL(
            provider: agentSource,
            homeDirectory: homeDirectory,
            environment: environment
        ),
              let data = AgentHookSessionRegistryReader.recordData(
                  provider: agentSource,
                  sessionID: sessionID,
                  legacyURL: file,
                  environment: environment
              ) else {
            return nil
        }
        return Self.entry(sessionID: sessionID, data: data)
    }

    private static func entry(sessionID: String, data: Data) -> Entry? {
        guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let embeddedSessionID = entry["sessionId"] as? String,
           embeddedSessionID != sessionID {
            return nil
        }
        let updatedAt = (entry["updatedAt"] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:))
        return Entry(
            sessionID: sessionID,
            workspaceID: nonEmpty(entry["workspaceId"] as? String),
            surfaceID: nonEmpty(entry["surfaceId"] as? String),
            workingDirectory: nonEmpty(entry["cwd"] as? String),
            transcriptPath: nonEmpty(entry["transcriptPath"] as? String),
            pid: entry["pid"] as? Int,
            updatedAt: updatedAt
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

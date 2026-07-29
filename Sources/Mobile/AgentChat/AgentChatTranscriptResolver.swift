import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// Resolves the transcript JSONL path for an agent session.
///
/// A hook-recorded `transcriptPath` is preferred. For OMP it is authoritative:
/// if the recorded file disappears, no unrelated profile fallback may replace
/// it. Without a recorded path, agent-specific conventional roots are searched
/// (Claude projects, Codex rollouts, or OMP config/profile/XDG session roots).
struct AgentChatTranscriptResolver: Sendable {
    private let homeDirectory: URL
    /// Config-dir root for Claude (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    private let claudeConfigRoot: URL
    /// Config-dir root for Codex (`$CODEX_HOME` or `~/.codex`).
    private let codexConfigRoot: URL
    /// Environment used by OMP's shared profile/root resolver.
    private let environment: [String: String]

    /// Creates a resolver.
    ///
    /// The derived-path fallbacks honor the agents' own config-dir env
    /// overrides so a user who relocates their config (e.g. `CLAUDE_CONFIG_DIR`
    /// or `CODEX_HOME`, including via a launcher/subrouter) still has transcripts
    /// resolved. The PRIMARY source remains the hook-recorded absolute
    /// `transcriptPath`, which already encodes any custom dir; this only fixes
    /// the fallback used when no path was recorded (e.g. a codex session resumed
    /// out-of-band, resolved by scanning the sessions dir).
    ///
    /// - Parameters:
    ///   - homeDirectory: Injectable home directory for tests.
    ///   - environment: Injectable environment for tests; defaults to the
    ///     process environment. Empty/whitespace override values are ignored.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.claudeConfigRoot = Self.configRoot(
            override: environment["CLAUDE_CONFIG_DIR"],
            default: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        self.codexConfigRoot = Self.configRoot(
            override: environment["CODEX_HOME"],
            default: homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        )
    }

    /// Resolves a config-dir root from an env override, expanding a leading `~`,
    /// falling back to `defaultRoot` when the override is absent or blank.
    private static func configRoot(override: String?, default defaultRoot: URL) -> URL {
        guard let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return defaultRoot
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    ///   - deadline: Optional deadline for recursive fallback enumeration.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(
        for record: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant? = nil
    ) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
        }
        if hasAuthoritativeOmpTranscriptReference(record) {
            return nil
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex:
            return codexFallbackPath(sessionID: record.sessionID, deadline: deadline)
        case .omp:
            return ompFallbackPath(
                record: record,
                deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(3))
            )
        case .other:
            return nil
        }
    }

    /// Resolves only paths that are cheap to check from the main-actor mobile
    /// session list path. Codex's fallback scans the full sessions tree, so it is
    /// intentionally excluded here and remains available only when opening a
    /// transcript.
    func boundedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
        }
        if hasAuthoritativeOmpTranscriptReference(record) {
            return nil
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .omp:
            return ompFallbackPath(
                record: record,
                deadline: ContinuousClock.now.advanced(by: .milliseconds(100))
            )
        case .codex, .other:
            return nil
        }
    }

    private func recordedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        guard let recorded = record.transcriptPath else { return nil }
        let expanded = (recorded as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
    }

    private func hasAuthoritativeOmpTranscriptReference(_ record: AgentChatSessionRecord) -> Bool {
        record.agentKind == .omp && record.transcriptPath != nil
    }

    private func claudeFallbackPath(record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
        guard let cwd = record.workingDirectory else { return nil }
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let path = claudeConfigRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent("\(record.hookStoreLookupSessionID).jsonl", isDirectory: false)
            .path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    /// Resolves OMP history from the shared launch resolver's valid
    /// config/profile/XDG session roots and current plus legacy cwd buckets.
    private func ompFallbackPath(
        record: AgentChatSessionRecord,
        deadline: ContinuousClock.Instant
    ) -> String? {
        guard !Task.isCancelled,
              ContinuousClock.now < deadline,
              let currentDirectory = record.workingDirectory,
              !currentDirectory.isEmpty else {
            return nil
        }
        let fileManager = FileManager.default
        let directoryResolver = OmpDirectoryResolver()
        let roots = directoryResolver.sessionRoots(
            environment: environment,
            homeDirectory: homeDirectory.path,
            currentDirectory: currentDirectory,
            fileManager: fileManager
        )
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        let bucketNames = directoryResolver.cwdBucketNames(
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory.path,
            fileManager: fileManager
        )
        for root in roots {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
            let directories = root.usesCwdBuckets
                ? bucketNames.searchOrder.map {
                    rootURL.appendingPathComponent($0, isDirectory: true)
                }
                : [rootURL]
            for directory in directories {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
                guard let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for transcript in files {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else {
                        return nil
                    }
                    if transcript.pathExtension == "jsonl",
                       transcript.lastPathComponent.contains(record.sessionID) {
                        return transcript.path
                    }
                }
            }
        }
        return nil
    }

    /// Codex rollout files are named `rollout-<timestamp>-<session-uuid>.jsonl`
    /// under `~/.codex/sessions/YYYY/MM/DD/`; scan recent day directories for
    /// the session id.
    private func codexFallbackPath(
        sessionID: String,
        deadline: ContinuousClock.Instant?
    ) -> String? {
        guard !Task.isCancelled else { return nil }
        if let deadline, ContinuousClock.now >= deadline {
            return nil
        }
        let fileManager = FileManager.default
        let root = codexConfigRoot
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = sessionID.lowercased()
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            if let deadline, ContinuousClock.now >= deadline {
                return nil
            }
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.lowercased().contains(needle) {
                return url.path
            }
        }
        return nil
    }
}

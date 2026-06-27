import CmuxAgentChat
import Foundation

/// Resolves the transcript JSONL path for an agent session.
///
/// Preference order: the hook store's recorded `transcriptPath`, then the
/// agent-specific conventional location (claude: encoded-cwd project dir;
/// codex: rollout whose confirmed session id matches exactly).
struct AgentChatTranscriptResolver: Sendable {
    private let homeDirectory: URL
    private let now: @Sendable () -> Date
    private static let claudeTranscriptTitleReadLimit = 1_048_576
    private static let claudeTranscriptTitleChunkSize = 64 * 1024
    private static let claudeTranscriptTitleMaxLineBytes = 256 * 1024

    /// Creates a resolver.
    ///
    /// - Parameter homeDirectory: Injectable home directory for tests.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(for record: AgentChatSessionRecord) -> String? {
        if let recorded = recordedTranscriptPath(for: record) {
            return recorded
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

    /// Returns the hook-recorded transcript path when it still exists.
    ///
    /// This is intentionally cheap enough for main-actor call sites; it does not
    /// run any agent-specific fallback scan.
    func recordedTranscriptPath(for record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
        guard let recorded = record.transcriptPath else { return nil }
        let expanded = (recorded as NSString).expandingTildeInPath
        return fileManager.fileExists(atPath: expanded) ? expanded : nil
    }

    /// The newest Claude transcript in a working directory's project dir,
    /// with its session id (the filename stem).
    ///
    /// Used to adopt a Claude session cmux detected by terminal title but
    /// that never ran a hook (e.g. launched through a shell wrapper that
    /// bypasses cmux's hook injection), so we never learned its session id.
    /// The newest `.jsonl` in the cwd's project dir is the live conversation.
    ///
    /// - Parameters:
    ///   - workingDirectory: The agent's working directory.
    ///   - excludingSessionIDs: Session ids already bound to another surface;
    ///     their transcripts are skipped so two hook-bypassed claudes in the
    ///     same directory each adopt a distinct conversation instead of both
    ///     resolving to the single newest file (and the second getting nothing).
    /// - Returns: The session id and absolute transcript path of the newest
    ///   unclaimed transcript, or `nil` when none is found.
    func newestClaudeTranscript(
        workingDirectory: String,
        excludingSessionIDs: Set<String> = [],
        titleHint: String? = nil
    ) -> (sessionID: String, path: String)? {
        guard !Task.isCancelled else { return nil }
        let fileManager = FileManager.default
        // The home project dir is a junk drawer of every home-rooted claude
        // conversation, so newest-by-mtime there is almost never *this*
        // terminal's session. Refuse title-detected adoption from $HOME; a
        // hooked claude in ~ still resolves by its exact session id via
        // `claudeFallbackPath`, so only the fuzzy path is blocked.
        let home = homeDirectory.resolvingSymlinksInPath().path
        // claude encodes the project dir from the cwd it sees, which is the
        // symlink-resolved path (getcwd → /private/tmp), while a panel's cwd
        // is often the unresolved form (/tmp). Try every form so a /tmp-rooted
        // terminal still finds its /private/tmp transcript dir.
        let candidates = Self.cwdCandidates(workingDirectory)
            .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != home }
        let normalizedTitleHint = Self.normalizedClaudeTitle(titleHint)
        for cwd in candidates {
            guard !Task.isCancelled else { return nil }
            let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
            let dir = homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectDir, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var transcriptCandidates: [(url: URL, date: Date, title: String?)] = []
            for url in entries where url.pathExtension == "jsonl" {
                guard !Task.isCancelled else { return nil }
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard !excludingSessionIDs.contains(sessionID) else { continue }
                transcriptCandidates.append((
                    url: url,
                    date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                    title: Self.claudeTranscriptTitle(at: url)
                ))
            }
            let newest: URL?
            if let normalizedTitleHint {
                let exactTitleCandidates = transcriptCandidates
                    .filter { Self.normalizedClaudeTitle($0.title) == normalizedTitleHint }
                let untitledCandidates = transcriptCandidates.filter { $0.title == nil }
                let newestExact = exactTitleCandidates.max { $0.date < $1.date }
                let newestUntitled = untitledCandidates.max { $0.date < $1.date }
                if let newestExact,
                   let newestUntitled,
                   newestUntitled.date > newestExact.date {
                    return nil
                }
                newest = (newestExact ?? newestUntitled)?.url
            } else {
                // A generic "Claude Code" title cannot identify one of several
                // same-cwd sessions. Avoid stealing a transcript that already
                // has a conversation title; a later title-change scan can bind
                // it to the matching terminal.
                newest = transcriptCandidates
                    .filter { $0.title == nil }
                    .max { $0.date < $1.date }?
                    .url
            }
            if let newest {
                return (sessionID: newest.deletingPathExtension().lastPathComponent, path: newest.path)
            }
        }
        return nil
    }

    /// Every cwd form claude might have encoded its project dir from, most
    /// specific first. `URL.resolvingSymlinksInPath()` is not enough on its
    /// own: across macOS versions it strips a leading `/private` but does NOT
    /// add one (so `/tmp` stays `/tmp` instead of becoming `/private/tmp`),
    /// yet claude's `getcwd` returns the `/private`-prefixed form. So toggle
    /// the `/private` prefix explicitly on both the raw and symlink-resolved
    /// paths, deduped in order. Existence-free, so it works before the dir is
    /// created.
    static func cwdCandidates(_ workingDirectory: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            result.append(path)
        }
        let privateRoot = "/private"
        for base in [workingDirectory, URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path] {
            add(base)
            if base.hasPrefix(privateRoot + "/") {
                add(String(base.dropFirst(privateRoot.count)))
            } else if base.hasPrefix("/") {
                add(privateRoot + base)
            }
        }
        return result
    }

    private func claudeFallbackPath(record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
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
        let fileManager = FileManager.default
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return nil }
        let root = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        return CodexTranscriptLocator().transcriptPath(
            sessionID: normalizedSessionID,
            sessionsURL: root,
            fileManager: fileManager,
            now: now()
        )
    }

    private static func normalizedClaudeTitle(_ title: String?) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        while let first = title.first, !first.isLetter && !first.isNumber {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = title.lowercased()
        guard !normalized.isEmpty,
              normalized != "claude code",
              !normalized.hasPrefix("claude ·") else {
            return nil
        }
        return normalized
    }

    private static func claudeTranscriptTitle(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var buffered = Data()
        var bytesRead = 0
        var droppingOversizedLine = false
        while bytesRead < claudeTranscriptTitleReadLimit {
            guard !Task.isCancelled else { return nil }
            let readSize = min(claudeTranscriptTitleChunkSize, claudeTranscriptTitleReadLimit - bytesRead)
            guard let chunk = try? handle.read(upToCount: readSize),
                  !chunk.isEmpty else {
                break
            }
            bytesRead += chunk.count
            buffered.append(chunk)

            while let newlineIndex = buffered.firstIndex(of: 0x0A) {
                let lineData = Data(buffered[..<newlineIndex])
                buffered.removeSubrange(...newlineIndex)
                if droppingOversizedLine {
                    droppingOversizedLine = false
                    continue
                }
                if let title = claudeTranscriptTitle(in: lineData) {
                    return title
                }
            }

            if buffered.count > claudeTranscriptTitleMaxLineBytes {
                buffered.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
        }
        guard !droppingOversizedLine else {
            return nil
        }
        return claudeTranscriptTitle(in: buffered)
    }

    private static func claudeTranscriptTitle(in lineData: Data) -> String? {
        guard lineData.range(of: Data(#""ai-title""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              object["type"] as? String == "ai-title" else {
            return nil
        }
        return object["aiTitle"] as? String
    }
}

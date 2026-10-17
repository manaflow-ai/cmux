import Foundation

/// Reads Cursor CLI JSONL transcripts and optional cmux hook metadata for Vault.
public actor CursorSessionIndex {
    private struct HookMetadata {
        let title: String?
        let workingDirectory: String?
        let updatedAt: Date?
    }

    private struct Candidate {
        let sessionID: String
        let transcriptURL: URL
        let modifiedAt: Date
        let hookMetadata: HookMetadata?
    }

    private static let maximumTitleCharacters = 160

    private let projectsRoot: URL
    private let hookStoreURL: URL?
    private let fileManager: FileManager
    private let maximumCandidateFiles: Int

    /// Creates an index for the current user's standard Cursor and cmux data directories.
    public init() {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        self.projectsRoot = homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        self.hookStoreURL = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("cursor-hook-sessions.json", isDirectory: false)
        self.fileManager = fileManager
        self.maximumCandidateFiles = 1_500
    }

    /// Creates an index with injected filesystem locations.
    ///
    /// Tests can point both locations at a temporary directory, so they never read or
    /// mutate the developer's Cursor installation.
    ///
    /// - Parameters:
    ///   - projectsRoot: Directory whose children contain `agent-transcripts` folders.
    ///   - hookStoreURL: Optional cmux Cursor hook-store file used to recover cwd and title.
    ///   - fileManager: Filesystem implementation used for discovery and reads.
    ///   - maximumCandidateFiles: Upper bound on transcripts inspected by one query.
    public init(
        projectsRoot: URL,
        hookStoreURL: URL?,
        fileManager: FileManager = .default,
        maximumCandidateFiles: Int = 1_500
    ) {
        self.projectsRoot = projectsRoot.standardizedFileURL
        self.hookStoreURL = hookStoreURL?.standardizedFileURL
        self.fileManager = fileManager
        self.maximumCandidateFiles = max(0, maximumCandidateFiles)
    }

    /// Loads one stable, newest-first page of Cursor sessions.
    ///
    /// Search matches the session id, title, captured cwd, or any transcript text.
    /// Directory filtering only keeps sessions whose hook metadata identifies the
    /// requested cwd.
    ///
    /// - Parameters:
    ///   - needle: Case-insensitive literal search text. Empty text lists recent sessions.
    ///   - workingDirectoryFilter: Exact normalized cwd to retain, or `nil` for all folders.
    ///   - offset: Number of matching sessions to skip.
    ///   - limit: Maximum number of sessions to return.
    /// - Returns: The requested sessions plus sanitized, deduplicated read failures.
    public func loadSessions(
        needle: String,
        workingDirectoryFilter: String?,
        offset: Int,
        limit: Int
    ) -> (sessions: [CursorIndexedSession], errors: [CursorSessionIndexError]) {
        guard offset >= 0, limit > 0 else {
            return ([], [])
        }
        let (target, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else {
            return ([], [])
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: projectsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ([], [])
        }

        let hookMetadata = loadHookMetadata()
        var errors = Set<CursorSessionIndexError>()
        let candidates = discoverCandidates(
            hookMetadata: hookMetadata,
            errors: &errors
        )
        let normalizedNeedle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilter = Self.normalizedPath(workingDirectoryFilter)

        var seenSessionIDs = Set<String>()
        var matchedCount = 0
        var sessions: [CursorIndexedSession] = []
        sessions.reserveCapacity(limit)

        for candidate in candidates.prefix(maximumCandidateFiles) {
            if Task.isCancelled || matchedCount >= target {
                break
            }
            guard seenSessionIDs.insert(candidate.sessionID).inserted else {
                continue
            }

            let transcript: String
            do {
                transcript = try String(contentsOf: candidate.transcriptURL, encoding: .utf8)
            } catch {
                errors.insert(.transcriptUnreadable)
                continue
            }

            let cwd = Self.normalizedPath(candidate.hookMetadata?.workingDirectory)
            if let normalizedFilter, cwd != normalizedFilter {
                continue
            }

            let transcriptTitle = Self.firstUserMessage(in: transcript)
            let title = transcriptTitle ?? candidate.hookMetadata?.title ?? ""
            if !normalizedNeedle.isEmpty {
                let metadata = [candidate.sessionID, title, cwd ?? ""].joined(separator: "\n")
                guard metadata.localizedCaseInsensitiveContains(normalizedNeedle)
                    || transcript.localizedCaseInsensitiveContains(normalizedNeedle) else {
                    continue
                }
            }

            if matchedCount >= offset {
                sessions.append(CursorIndexedSession(
                    sessionID: candidate.sessionID,
                    title: title,
                    workingDirectory: cwd,
                    modifiedAt: candidate.modifiedAt,
                    transcriptURL: candidate.transcriptURL
                ))
            }
            matchedCount += 1
        }

        return (sessions, Self.orderedErrors(errors))
    }

    private func discoverCandidates(
        hookMetadata: [String: HookMetadata],
        errors: inout Set<CursorSessionIndexError>
    ) -> [Candidate] {
        let workspaceURLs: [URL]
        do {
            workspaceURLs = try fileManager.contentsOfDirectory(
                at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            errors.insert(.projectsDirectoryUnreadable)
            return []
        }

        var candidates: [Candidate] = []
        for workspaceURL in workspaceURLs {
            guard Self.isDirectory(workspaceURL) else { continue }
            let transcriptsRoot = workspaceURL
                .appendingPathComponent("agent-transcripts", isDirectory: true)
            guard Self.isDirectory(transcriptsRoot) else { continue }

            let sessionURLs: [URL]
            do {
                sessionURLs = try fileManager.contentsOfDirectory(
                    at: transcriptsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                errors.insert(.projectsDirectoryUnreadable)
                continue
            }

            for sessionURL in sessionURLs where Self.isDirectory(sessionURL) {
                let transcriptURLs: [URL]
                do {
                    transcriptURLs = try fileManager.contentsOfDirectory(
                        at: sessionURL,
                        includingPropertiesForKeys: [
                            .contentModificationDateKey,
                            .isRegularFileKey,
                        ],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    errors.insert(.projectsDirectoryUnreadable)
                    continue
                }

                for transcriptURL in transcriptURLs where transcriptURL.pathExtension == "jsonl" {
                    guard let values = try? transcriptURL.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]
                    ),
                    values.isRegularFile == true,
                    let transcriptModifiedAt = values.contentModificationDate else {
                        continue
                    }
                    let sessionID = transcriptURL.deletingPathExtension().lastPathComponent
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !sessionID.isEmpty else { continue }

                    let metadata = hookMetadata[sessionID]
                    let modifiedAt = max(
                        transcriptModifiedAt,
                        metadata?.updatedAt ?? .distantPast
                    )
                    candidates.append(Candidate(
                        sessionID: sessionID,
                        transcriptURL: transcriptURL.standardizedFileURL,
                        modifiedAt: modifiedAt,
                        hookMetadata: metadata
                    ))
                }
            }
        }

        return candidates.sorted {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.transcriptURL.path < $1.transcriptURL.path
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func loadHookMetadata() -> [String: HookMetadata] {
        guard let hookStoreURL,
              let data = try? Data(contentsOf: hookStoreURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            return [:]
        }

        var metadataBySessionID: [String: HookMetadata] = [:]
        for (storeKey, value) in sessions {
            guard let record = value as? [String: Any] else { continue }
            let sessionID = Self.normalizedText(record["sessionId"] as? String)
                ?? Self.normalizedText(storeKey)
            guard let sessionID else { continue }

            let launchCommand = record["launchCommand"] as? [String: Any]
            let cwd = Self.normalizedText(record["cwd"] as? String)
                ?? Self.normalizedText(launchCommand?["workingDirectory"] as? String)
            let title = Self.normalizedText(record["title"] as? String)
            let updatedAt = (record["updatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            let candidate = HookMetadata(
                title: title,
                workingDirectory: cwd,
                updatedAt: updatedAt
            )
            if let existing = metadataBySessionID[sessionID],
               (existing.updatedAt ?? .distantPast) > (candidate.updatedAt ?? .distantPast) {
                continue
            }
            metadataBySessionID[sessionID] = candidate
        }
        return metadataBySessionID
    }

    private static func firstUserMessage(in transcript: String) -> String? {
        for line in transcript.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  normalizedText(object["role"] as? String)?.lowercased() == "user",
                  let message = object["message"] as? [String: Any],
                  let text = firstTextFragment(in: message["content"]) else {
                continue
            }
            return boundedTitle(text)
        }
        return nil
    }

    private static func firstTextFragment(in value: Any?) -> String? {
        if let string = value as? String {
            return normalizedText(string)
        }
        guard let parts = value as? [Any] else { return nil }
        for part in parts {
            if let string = part as? String,
               let normalized = normalizedText(string) {
                return normalized
            }
            guard let object = part as? [String: Any] else { continue }
            let type = normalizedText(object["type"] as? String)?.lowercased()
            guard type == nil || type == "text" || type == "input_text" else {
                continue
            }
            if let text = normalizedText(
                object["text"] as? String ?? object["content"] as? String
            ) {
                return text
            }
        }
        return nil
    }

    private static func boundedTitle(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maximumTitleCharacters))
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value = normalizedText(value) else { return nil }
        return URL(
            fileURLWithPath: NSString(string: value).expandingTildeInPath,
            isDirectory: true
        )
        .standardizedFileURL
        .path
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func orderedErrors(
        _ errors: Set<CursorSessionIndexError>
    ) -> [CursorSessionIndexError] {
        [
            .projectsDirectoryUnreadable,
            .transcriptUnreadable,
        ].filter(errors.contains)
    }
}

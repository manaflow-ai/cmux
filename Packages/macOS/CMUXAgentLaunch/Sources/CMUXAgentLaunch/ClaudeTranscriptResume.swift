import Foundation

/// Encodes a filesystem path into the project-directory name Claude derives from it.
///
/// Claude namespaces each session transcript under
/// `<config>/projects/<encoded-cwd>/<session-id>.jsonl`, where the encoding replaces both `/` and
/// `.` with `-` (e.g. `/Users/x/repo/.claude` -> `-Users-x-repo--claude`). This is the single
/// source of truth for that encoding, shared by the app's session index and the CLI's resume-binding
/// publisher so both look in the directory Claude actually stores the transcript in.
public enum ClaudeProjectDirEncoding {
    public static func projectDirName(forPath path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}

/// Resolves which working directory a resumed Claude session must `cd` into so `claude --resume <id>`
/// finds its transcript.
///
/// Claude addresses transcripts by the cwd the session was *created* in, not the runtime cwd the agent
/// later `cd`'d into (e.g. a repo root drifting into a worktree). Given the candidate directories (the
/// launch cwd and the last-reported runtime cwd), this returns the one whose encoded project directory
/// actually holds the transcript on disk — matched first against the transcript's own storage path,
/// then by probing the Claude config roots — or `nil` when neither can be verified, so the caller can
/// fall back to the launch cwd instead of the drift-prone runtime cwd.
///
/// This mirrors the app-side snapshot resolver (`RestorableAgentSessionIndex`) and is shared with the
/// CLI resume-binding publisher (`publishAgentSurfaceResumeBinding` in the `cmux-cli` target) so both
/// the snapshot path and the `source: agent-hook` auto-resume binding path apply one policy.
public struct ClaudeResumeWorkingDirectory {
    private let fileManager: FileManager
    private let homeDirectory: String
    // A reference-type cache so that reusing one instance across a session-index load loop shares the
    // (expensive) config-root scan and per-project transcript probes instead of redoing them per call.
    private let cache: TranscriptLookupCache

    public init(fileManager: FileManager = .default, homeDirectory: String = NSHomeDirectory()) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.cache = TranscriptLookupCache(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    /// Returns the candidate working directory whose Claude project folder actually holds the
    /// transcript for `sessionId`, or `nil` when neither candidate can be verified.
    ///
    /// - Parameters:
    ///   - sessionId: the Claude session id (transcript file stem).
    ///   - transcriptPath: the transcript path Claude reported, if any. Its parent project directory
    ///     names the directory Claude resumes from.
    ///   - claudeConfigDir: the session's `CLAUDE_CONFIG_DIR`, if it ran with a non-default config dir.
    ///   - candidateWorkingDirectories: directories to verify, in priority order (typically
    ///     `[launchCwd, runtimeCwd]`). Empty/blank entries are ignored.
    public func verifiedWorkingDirectory(
        sessionId: String,
        transcriptPath: String?,
        claudeConfigDir: String?,
        candidateWorkingDirectories: [String]
    ) -> String? {
        guard let sessionId = normalizedNonEmptyValue(sessionId),
              sessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        let candidates = candidateWorkingDirectories.compactMap { normalizedNonEmptyValue($0) }
        guard !candidates.isEmpty else { return nil }

        let roots = cache.configRoots(claudeConfigDir: claudeConfigDir)

        if let transcriptPath = normalizedNonEmptyValue(transcriptPath) {
            let expandedTranscriptPath = (transcriptPath as NSString).expandingTildeInPath
            // The transcript's own storage path names the project directory Claude looks in.
            let expectedProjectDirName = projectDirName(
                containingTranscriptPath: expandedTranscriptPath,
                sessionId: sessionId,
                configRoots: roots
            )

            if let expectedProjectDirName, !expectedProjectDirName.isEmpty {
                // (a) Prefer a candidate whose encoding matches that project directory.
                if let matched = candidates.first(where: {
                    ClaudeProjectDirEncoding.projectDirName(forPath: $0) == expectedProjectDirName
                }) {
                    return matched
                }

                // (b) No candidate matches — the true launch cwd is not among them (e.g. the launch
                // capture itself collapsed to the drifted runtime cwd). Recover it directly from the
                // transcript: every Claude record carries the session's launch cwd in a top-level
                // "cwd". Only trust it when its re-encoding round-trips to the same project
                // directory, so a lossy/foreign path can never be accepted.
                if let recovered = recordedCwd(inTranscriptAtPath: expandedTranscriptPath),
                   ClaudeProjectDirEncoding.projectDirName(forPath: recovered) == expectedProjectDirName {
                    return recovered
                }
            }
        }

        // (c) Probe the config directory for the candidate that holds the transcript on disk.
        if !roots.isEmpty {
            for candidate in candidates {
                let dirName = ClaudeProjectDirEncoding.projectDirName(forPath: candidate)
                for root in roots where cache.transcriptPath(
                    configRoot: root,
                    projectDirName: dirName,
                    sessionId: sessionId
                ) != nil {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Reads the launch cwd Claude records on every transcript record (top-level `"cwd"`). The read
    /// is bounded so a huge or mid-write transcript never stalls the hook — the cwd appears on the
    /// first record, so a head read suffices.
    private func recordedCwd(inTranscriptAtPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty,
              let text = String(data: chunk, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = normalizedNonEmptyValue(object["cwd"] as? String) else {
                continue
            }
            return cwd
        }
        return nil
    }

    private func sessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    /// The project directory segment of a Claude transcript path. Resolves against a known config
    /// root when possible; otherwise infers it from the known transcript shapes
    /// `<project>/<id>.jsonl` and the nested `<project>/<id>/messages/<id>.jsonl`, so recovery works
    /// even when the config root is unknown.
    private func projectDirName(
        containingTranscriptPath path: String,
        sessionId: String,
        configRoots: [String]
    ) -> String? {
        let standardizedPath = (path as NSString).standardizingPath
        for root in configRoots {
            let projectsRoot = ((root as NSString).appendingPathComponent("projects") as NSString)
                .standardizingPath
            let prefix = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
            guard standardizedPath.hasPrefix(prefix) else { continue }
            let relativePath = String(standardizedPath.dropFirst(prefix.count))
            guard let projectDirName = relativePath.split(separator: "/", maxSplits: 1).first,
                  !projectDirName.isEmpty else {
                continue
            }
            return String(projectDirName)
        }

        // Config root unknown — infer from the transcript shape. Walk up from the file: the nested
        // layout puts `<id>/messages/` between the project dir and the file, so skip those segments.
        var dir = (standardizedPath as NSString).deletingLastPathComponent
        if (dir as NSString).lastPathComponent == "messages" {
            dir = (dir as NSString).deletingLastPathComponent
            if (dir as NSString).lastPathComponent == sessionId {
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Caches config-root discovery and per-project transcript lookups for one resolution pass.
    private final class TranscriptLookupCache {
        private let homeDirectory: String
        private let fileManager: FileManager
        private var transcriptPathByProjectRootAndSession: [String: String] = [:]
        private var missingTranscriptPathByProjectRootAndSession: Set<String> = []
        private var configRootsByConfigDir: [String: [String]] = [:]

        init(homeDirectory: String, fileManager: FileManager) {
            self.homeDirectory = homeDirectory
            self.fileManager = fileManager
        }

        func configRoots(claudeConfigDir: String?) -> [String] {
            // Memoize so reusing the cache across a load loop scans the account roots once.
            let key = normalizedNonEmptyValue(claudeConfigDir) ?? ""
            if let cached = configRootsByConfigDir[key] {
                return cached
            }
            let resolved = computeConfigRoots(claudeConfigDir: claudeConfigDir)
            configRootsByConfigDir[key] = resolved
            return resolved
        }

        private func computeConfigRoots(claudeConfigDir: String?) -> [String] {
            if let configured = normalizedNonEmptyValue(claudeConfigDir) {
                return [
                    ClaudeConfigDirectoryPath.preferredPath(
                        configured,
                        fileManager: fileManager,
                        homeDirectory: homeDirectory
                    ),
                ]
            }

            var roots: [String] = []
            var seen: Set<String> = []
            func appendRoot(_ path: String) {
                let standardized = (path as NSString).standardizingPath
                guard seen.insert(standardized).inserted else { return }
                roots.append(standardized)
            }

            let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
            if directoryExists(atPath: accountRoot),
               let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
                for accountDir in accountDirs.sorted() {
                    appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
                }
            }
            appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
            appendRoot(
                ClaudeConfigDirectoryPath.preferredPath(
                    (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                )
            )
            return roots
        }

        func transcriptPath(configRoot: String, projectDirName: String, sessionId: String) -> String? {
            let standardizedRoot = (configRoot as NSString).standardizingPath
            let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
            let projectRoot = ((projectsRoot as NSString).appendingPathComponent(projectDirName) as NSString)
                .standardizingPath
            let key = cacheKey(projectRoot, sessionId)
            if let cached = transcriptPathByProjectRootAndSession[key] {
                return cached
            }
            if missingTranscriptPathByProjectRootAndSession.contains(key) {
                return nil
            }

            let path = Self.transcriptPath(
                inProjectRoot: projectRoot,
                sessionId: sessionId,
                fileManager: fileManager
            )
            if let path {
                transcriptPathByProjectRootAndSession[key] = path
            } else {
                missingTranscriptPathByProjectRootAndSession.insert(key)
            }
            return path
        }

        private static func transcriptPath(
            inProjectRoot projectRoot: String,
            sessionId: String,
            fileManager: FileManager
        ) -> String? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: projectRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }

            let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
            if regularNonEmptyFileExists(atPath: directPath, fileManager: fileManager) {
                return directPath
            }

            let nestedMessagesPath = (((projectRoot as NSString)
                .appendingPathComponent(sessionId) as NSString)
                .appendingPathComponent("messages") as NSString)
                .appendingPathComponent("\(sessionId).jsonl")
            if regularNonEmptyFileExists(atPath: nestedMessagesPath, fileManager: fileManager) {
                return nestedMessagesPath
            }
            return nil
        }

        private static func regularNonEmptyFileExists(atPath path: String, fileManager: FileManager) -> Bool {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 0
        }

        private func directoryExists(atPath path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        private func normalizedNonEmptyValue(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        private func cacheKey(_ prefix: String, _ sessionId: String) -> String {
            prefix + "\u{0}" + sessionId
        }
    }
}

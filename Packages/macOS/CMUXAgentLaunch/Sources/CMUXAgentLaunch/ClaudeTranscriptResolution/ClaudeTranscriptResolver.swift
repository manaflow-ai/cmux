import Foundation

/// Resolves Claude session transcripts on disk: it maps a launch cwd to Claude's
/// `projects/<encoded>/` directory, verifies which candidate directory actually
/// holds a session's `<sessionId>.jsonl`, heals workflow-container records to the
/// newest sibling transcript, and finds the latest session id for a cwd.
///
/// The engine is a value type carrying only its `FileManager`; the reused config
/// scan lives in ``ClaudeTranscriptLookupCache``, passed in per call. Inputs come
/// in as a ``ClaudeTranscriptQuery`` so the resolver never references the
/// app-target hook record.
public struct ClaudeTranscriptResolver {
    private let fileManager: FileManager

    public init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    /// Claude derives a project directory name by replacing both "/" and "." with
    /// "-" (e.g. "/Users/x/repo/.claude" -> "-Users-x-repo--claude"). Missing the
    /// "." case sent dotted paths to the wrong project directory.
    public static func projectDirectoryName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Heals a workflow-container record: when the recorded session has no readable
    /// transcript at its recorded path, returns the newest sibling `.jsonl` in the
    /// session's workflow project directories, or `nil` to keep the record as-is.
    public func resolveWorkflowTranscript(
        query: ClaudeTranscriptQuery,
        lookup: ClaudeTranscriptLookupCache
    ) -> (sessionId: String, path: String)? {
        guard let sessionId = Self.normalizedNonEmptyValue(query.sessionId),
              Self.sessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        if let transcriptPath = Self.normalizedNonEmptyValue(query.transcriptPath),
           regularNonEmptyFileExists(atPath: (transcriptPath as NSString).expandingTildeInPath) {
            return nil
        }

        let roots = lookup.configRoots(forClaudeConfigDir: query.claudeConfigDir)
        guard !roots.isEmpty else { return nil }
        let candidateProjectDirs = workflowProjectDirs(
            query: query,
            sessionId: sessionId,
            roots: roots,
            lookup: lookup
        )
        return newestSiblingTranscript(in: candidateProjectDirs, excludingSessionId: sessionId)
    }

    /// Whether a Claude record has a restorable transcript: either the recorded
    /// transcript path is a readable non-empty file, or a matching `<sessionId>.jsonl`
    /// exists under one of the config roots.
    public func hasRestorableTranscript(
        query: ClaudeTranscriptQuery,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        if let transcriptPath = Self.normalizedNonEmptyValue(query.transcriptPath),
           regularNonEmptyFileExists(atPath: (transcriptPath as NSString).expandingTildeInPath) {
            return true
        }
        return transcriptExists(query: query, lookup: lookup)
    }

    /// For Claude, returns the candidate directory (`launchCwd` then `recordedCwd`)
    /// whose project folder actually holds the transcript, matched first against the
    /// transcript's known storage path then against the config directory on disk, or
    /// `nil` when neither can be verified.
    public func verifiedRestorableWorkingDirectory(
        query: ClaudeTranscriptQuery,
        recordedCwd: String?,
        launchCwd: String?,
        lookup: ClaudeTranscriptLookupCache
    ) -> String? {
        guard let sessionId = Self.normalizedNonEmptyValue(query.sessionId),
              Self.sessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        let candidates = [launchCwd, recordedCwd].compactMap { $0 }

        // The transcript's own storage path names the project directory Claude will look in,
        // so the candidate whose encoding matches it is the one Claude can resume from.
        if let transcriptPath = Self.normalizedNonEmptyValue(query.transcriptPath) {
            let expandedTranscriptPath = (transcriptPath as NSString).expandingTildeInPath
            let projectDir = (expandedTranscriptPath as NSString).deletingLastPathComponent
            let expectedProjectDirName = (projectDir as NSString).lastPathComponent
            if !expectedProjectDirName.isEmpty,
               let matched = candidates.first(where: {
                   Self.projectDirectoryName(for: $0) == expectedProjectDirName
               }) {
                return matched
            }
        }

        // Probe the config directory for the candidate that holds the transcript on disk.
        let roots = lookup.configRoots(forClaudeConfigDir: query.claudeConfigDir)
        if !roots.isEmpty {
            for candidate in candidates {
                let projectDirName = Self.projectDirectoryName(for: candidate)
                for root in roots where transcriptFileExists(
                    configRoot: root,
                    projectDirName: projectDirName,
                    sessionId: sessionId
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Resolves the newest Claude transcript session id for `cwd` (honoring an
    /// optional `CLAUDE_CONFIG_DIR`), reusing the exact config-root + project-dir
    /// lookup the hook-store path uses. Used by live-process detection so a
    /// hook-less `claude` process (e.g. launched via `sr claude`, bypassing the
    /// cmux wrapper) still yields a fork-able session id.
    public func newestSessionId(
        forCwd cwd: String,
        configDir: String?,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        guard let normalizedCwd = Self.normalizedNonEmptyValue(cwd) else { return nil }
        let lookup = ClaudeTranscriptLookupCache(homeDirectory: homeDirectory, fileManager: fileManager)
        let encoded = Self.projectDirectoryName(for: normalizedCwd)
        var projectDirs: [String] = []
        var seen: Set<String> = []
        for root in lookup.configRoots(forClaudeConfigDir: configDir) {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            let projectDir = (projectsRoot as NSString).appendingPathComponent(encoded)
            let standardized = (projectDir as NSString).standardizingPath
            if seen.insert(standardized).inserted {
                projectDirs.append(standardized)
            }
        }
        return newestSiblingTranscript(
            in: projectDirs,
            excludingSessionId: ""
        )?.sessionId
    }

    private func workflowProjectDirs(
        query: ClaudeTranscriptQuery,
        sessionId: String,
        roots: [String],
        lookup: ClaudeTranscriptLookupCache
    ) -> [String] {
        var projectDirs: [String] = []
        var seen: Set<String> = []

        func appendIfWorkflowContainer(projectRoot: String) {
            let workflowContainer = (projectRoot as NSString).appendingPathComponent(sessionId)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: workflowContainer, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let standardized = (projectRoot as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            projectDirs.append(standardized)
        }

        let cwdCandidates = [
            Self.normalizedWorkingDirectory(query.launchWorkingDirectory),
            Self.normalizedWorkingDirectory(query.cwd),
        ].compactMap { $0 }
        for root in roots {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            for cwd in cwdCandidates {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(Self.projectDirectoryName(for: cwd))
                )
            }
            for projectDir in lookup.projectDirs(configRoot: root) {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(projectDir)
                )
            }
        }
        return projectDirs
    }

    private func newestSiblingTranscript(
        in projectDirs: [String],
        excludingSessionId excludedSessionId: String
    ) -> (sessionId: String, path: String)? {
        var best: (sessionId: String, path: String, modifiedAt: TimeInterval)?
        for projectDir in projectDirs {
            guard let children = try? fileManager.contentsOfDirectory(atPath: projectDir) else {
                continue
            }
            for child in children where child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard sessionId != excludedSessionId,
                      Self.sessionIdIsSafeFilename(sessionId) else {
                    continue
                }
                let path = (projectDir as NSString).appendingPathComponent(child)
                guard regularNonEmptyFileExists(atPath: path) else {
                    continue
                }
                let modifiedAt = ((try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                    .timeIntervalSince1970 ?? 0
                if best == nil || modifiedAt > best!.modifiedAt {
                    best = (sessionId, path, modifiedAt)
                }
            }
        }
        guard let best else { return nil }
        return (best.sessionId, best.path)
    }

    private func transcriptExists(
        query: ClaudeTranscriptQuery,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        guard let sessionId = Self.normalizedNonEmptyValue(query.sessionId),
              Self.sessionIdIsSafeFilename(sessionId) else {
            return false
        }

        let roots = lookup.configRoots(forClaudeConfigDir: query.claudeConfigDir)
        guard !roots.isEmpty else { return false }

        let cwd = Self.normalizedWorkingDirectory(query.cwd)
            ?? Self.normalizedWorkingDirectory(query.launchWorkingDirectory)
        for root in roots {
            if let cwd,
               transcriptFileExists(
                   configRoot: root,
                   projectDirName: Self.projectDirectoryName(for: cwd),
                   sessionId: sessionId
               ) {
                return true
            }
            if transcriptFileExistsInAnyProject(
                configRoot: root,
                sessionId: sessionId,
                lookup: lookup
            ) {
                return true
            }
        }
        return false
    }

    private func transcriptFileExists(
        configRoot: String,
        projectDirName: String,
        sessionId: String
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDirName)
        let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        return regularNonEmptyFileExists(atPath: path)
    }

    private func transcriptFileExistsInAnyProject(
        configRoot: String,
        sessionId: String,
        lookup: ClaudeTranscriptLookupCache
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        for projectDir in lookup.projectDirs(configRoot: configRoot) {
            let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
            let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
            if regularNonEmptyFileExists(atPath: path) {
                return true
            }
        }
        return false
    }

    private func regularNonEmptyFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    static func sessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        normalizedNonEmptyValue(rawValue)
    }

    static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}

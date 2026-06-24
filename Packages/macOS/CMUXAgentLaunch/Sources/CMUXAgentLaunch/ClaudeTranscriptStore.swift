import Foundation

/// The hook-store fields a Claude transcript/project-dir lookup needs.
///
/// A plain value carrying only the String/optional fields the resolver reads,
/// so the package never imports the app's private `RestorableAgentHookSessionRecord`.
/// The app lowers its record into one of these at the call site.
public struct ClaudeTranscriptRecordInput: Sendable, Equatable {
    /// The session id Claude files the transcript under (`<sessionId>.jsonl`).
    public var sessionId: String?
    /// The agent's last-reported runtime cwd (may have drifted mid-session).
    public var cwd: String?
    /// The transcript's known storage path, when the hook recorded one.
    public var transcriptPath: String?
    /// The directory the agent was launched in (the stable session namespace).
    public var launchWorkingDirectory: String?
    /// The `CLAUDE_CONFIG_DIR` captured in the launch environment, if any.
    public var claudeConfigDirectory: String?

    /// Creates a transcript-lookup input from the raw hook-record fields.
    public init(
        sessionId: String?,
        cwd: String?,
        transcriptPath: String?,
        launchWorkingDirectory: String?,
        claudeConfigDirectory: String?
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.launchWorkingDirectory = launchWorkingDirectory
        self.claudeConfigDirectory = claudeConfigDirectory
    }
}

/// A Claude transcript resolved on disk: the session id and its `.jsonl` path.
public struct ClaudeTranscriptResolution: Sendable, Equatable {
    /// The session id parsed from the transcript filename.
    public let sessionId: String
    /// The absolute path to the transcript `.jsonl` file.
    public let path: String

    /// Creates a resolved transcript.
    public init(sessionId: String, path: String) {
        self.sessionId = sessionId
        self.path = path
    }
}

/// Resolves Claude session transcripts and the project directories Claude files
/// them under, honoring `CLAUDE_CONFIG_DIR` and the account/legacy config roots.
///
/// Claude stores each session as `<configRoot>/projects/<encode(cwd)>/<sessionId>.jsonl`.
/// This type encapsulates the config-root + project-dir discovery, transcript
/// existence probes, sibling-transcript selection, and the launch-cwd verification
/// that the session index and live-process detection share.
///
/// The type is a value constructed per resolution pass
/// (`ClaudeTranscriptStore(fileManager:homeDirectory:)`); it holds a private
/// per-instance lookup cache so repeated config-root and project-dir reads within
/// one pass hit disk once. It is intentionally not `Sendable`: the cache is a
/// reference, and the store is used within a single synchronous pass, never
/// crossed across isolation domains.
public struct ClaudeTranscriptStore {
    private let fileManager: FileManager
    private let homeDirectory: String
    private let lookup: ClaudeTranscriptLookupCache

    /// Creates a transcript store with a fresh lookup cache.
    ///
    /// - Parameters:
    ///   - fileManager: the filesystem to probe (inject a scoped one in tests).
    ///   - homeDirectory: the home directory whose `.claude`, `.codex-accounts/claude`,
    ///     and `.subrouter/codex/claude` roots are searched.
    public init(fileManager: FileManager = .default, homeDirectory: String = NSHomeDirectory()) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.lookup = ClaudeTranscriptLookupCache(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    /// Encodes a cwd into the Claude project directory name.
    ///
    /// Claude derives a project directory name by replacing both "/" and "." with "-"
    /// (e.g. "/Users/x/repo/.claude" -> "-Users-x-repo--claude"). Missing the "." case
    /// sent dotted paths to the wrong project directory.
    public static func encodeClaudeProjectDir(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Resolves the newest Claude transcript session id for `cwd` (honoring an
    /// optional `CLAUDE_CONFIG_DIR`), reusing the exact config-root + project-dir
    /// lookup the hook-store path uses. Used by live-process detection so a
    /// hook-less `claude` process (e.g. launched via `sr claude`, bypassing the
    /// cmux wrapper) still yields a fork-able session id.
    public static func newestClaudeSessionId(
        forCwd cwd: String,
        configDir: String?,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        guard let normalizedCwd = normalizedNonEmptyValue(cwd) else { return nil }
        let store = ClaudeTranscriptStore(fileManager: fileManager, homeDirectory: homeDirectory)
        let record = ClaudeTranscriptRecordInput(
            sessionId: "",
            cwd: normalizedCwd,
            transcriptPath: nil,
            launchWorkingDirectory: normalizedCwd,
            claudeConfigDirectory: normalizedNonEmptyValue(configDir)
        )
        let encoded = encodeClaudeProjectDir(normalizedCwd)
        var projectDirs: [String] = []
        var seen: Set<String> = []
        for root in store.lookup.configRoots(for: record) {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            let projectDir = (projectsRoot as NSString).appendingPathComponent(encoded)
            let standardized = (projectDir as NSString).standardizingPath
            if seen.insert(standardized).inserted {
                projectDirs.append(standardized)
            }
        }
        return store.newestClaudeSiblingTranscript(
            in: projectDirs,
            excludingSessionId: ""
        )?.sessionId
    }

    /// Whether a restorable Claude transcript can be located for `record`.
    ///
    /// Mirrors the legacy claude branch of `hookRecordIsRestorable`: a recorded
    /// transcript path that exists wins immediately, otherwise the config roots
    /// are searched for the session's `.jsonl`.
    public func claudeTranscriptExists(for record: ClaudeTranscriptRecordInput) -> Bool {
        if let transcriptPath = Self.normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath
           ) {
            return true
        }
        guard let sessionId = Self.normalizedNonEmptyValue(record.sessionId),
              Self.claudeSessionIdIsSafeFilename(sessionId) else {
            return false
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return false }

        let cwd = normalizedWorkingDirectory(record.cwd)
            ?? normalizedWorkingDirectory(record.launchWorkingDirectory)
        for root in roots {
            if let cwd,
               claudeTranscriptFileExists(
                   configRoot: root,
                   projectDirName: Self.encodeClaudeProjectDir(cwd),
                   sessionId: sessionId
               ) {
                return true
            }
            if claudeTranscriptFileExistsInAnyProject(
                configRoot: root,
                sessionId: sessionId
            ) {
                return true
            }
        }
        return false
    }

    /// Re-resolves a workflow record whose recorded transcript is stale.
    ///
    /// When the recorded session id is a safe filename but its transcript is
    /// missing on disk, this scans the workflow's container project dirs for the
    /// newest sibling transcript and returns updated `(sessionId, transcriptPath)`
    /// values; otherwise it returns `nil` so the caller keeps the original record.
    public func resolvedClaudeWorkflow(
        for record: ClaudeTranscriptRecordInput
    ) -> ClaudeTranscriptResolution? {
        guard let sessionId = Self.normalizedNonEmptyValue(record.sessionId),
              Self.claudeSessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        if let transcriptPath = Self.normalizedNonEmptyValue(record.transcriptPath),
           regularNonEmptyFileExists(
               atPath: (transcriptPath as NSString).expandingTildeInPath
           ) {
            return nil
        }

        let roots = lookup.configRoots(for: record)
        guard !roots.isEmpty else { return nil }
        let candidateProjectDirs = claudeWorkflowProjectDirs(
            for: record,
            sessionId: sessionId,
            roots: roots
        )
        return newestClaudeSiblingTranscript(
            in: candidateProjectDirs,
            excludingSessionId: sessionId
        )
    }

    /// For Claude, returns the candidate directory whose project folder actually holds the
    /// transcript — matched first against the transcript's known storage path, then against the
    /// config directory on disk — or `nil` when neither can be verified (so the caller prefers the
    /// launch cwd instead of the drift-prone recorded cwd).
    public func claudeVerifiedRestorableWorkingDirectory(
        record: ClaudeTranscriptRecordInput,
        recordedCwd: String?,
        launchCwd: String?
    ) -> String? {
        guard let sessionId = Self.normalizedNonEmptyValue(record.sessionId),
              Self.claudeSessionIdIsSafeFilename(sessionId) else {
            return nil
        }
        let candidates = [launchCwd, recordedCwd].compactMap { $0 }

        // The transcript's own storage path names the project directory Claude will look in,
        // so the candidate whose encoding matches it is the one Claude can resume from.
        if let transcriptPath = Self.normalizedNonEmptyValue(record.transcriptPath) {
            let expandedTranscriptPath = (transcriptPath as NSString).expandingTildeInPath
            let projectDir = (expandedTranscriptPath as NSString).deletingLastPathComponent
            let expectedProjectDirName = (projectDir as NSString).lastPathComponent
            if !expectedProjectDirName.isEmpty,
               let matched = candidates.first(where: {
                   Self.encodeClaudeProjectDir($0) == expectedProjectDirName
               }) {
                return matched
            }
        }

        // Probe the config directory for the candidate that holds the transcript on disk.
        let roots = lookup.configRoots(for: record)
        if !roots.isEmpty {
            for candidate in candidates {
                let projectDirName = Self.encodeClaudeProjectDir(candidate)
                for root in roots where claudeTranscriptFileExists(
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

    // MARK: - Internal resolution helpers

    private func claudeWorkflowProjectDirs(
        for record: ClaudeTranscriptRecordInput,
        sessionId: String,
        roots: [String]
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
            normalizedWorkingDirectory(record.launchWorkingDirectory),
            normalizedWorkingDirectory(record.cwd),
        ].compactMap { $0 }
        for root in roots {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            for cwd in cwdCandidates {
                appendIfWorkflowContainer(
                    projectRoot: (projectsRoot as NSString).appendingPathComponent(Self.encodeClaudeProjectDir(cwd))
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

    private func newestClaudeSiblingTranscript(
        in projectDirs: [String],
        excludingSessionId excludedSessionId: String
    ) -> ClaudeTranscriptResolution? {
        var best: (sessionId: String, path: String, modifiedAt: TimeInterval)?
        for projectDir in projectDirs {
            guard let children = try? fileManager.contentsOfDirectory(atPath: projectDir) else {
                continue
            }
            for child in children where child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard sessionId != excludedSessionId,
                      Self.claudeSessionIdIsSafeFilename(sessionId) else {
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
        return ClaudeTranscriptResolution(sessionId: best.sessionId, path: best.path)
    }

    private func claudeTranscriptFileExists(
        configRoot: String,
        projectDirName: String,
        sessionId: String
    ) -> Bool {
        let projectsRoot = (configRoot as NSString).appendingPathComponent("projects")
        let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDirName)
        let path = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        return regularNonEmptyFileExists(atPath: path)
    }

    private func claudeTranscriptFileExistsInAnyProject(
        configRoot: String,
        sessionId: String
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

    private func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        Self.normalizedNonEmptyValue(rawValue)
    }

    static func claudeSessionIdIsSafeFilename(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    /// `value` trimmed of surrounding whitespace and newlines, or `nil` when it
    /// is missing or empty after trimming.
    static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}

/// Per-pass cache of Claude config roots and the project directories under each.
///
/// A reference type so one `ClaudeTranscriptStore` value shares it across the
/// many root/project-dir reads in a single resolution pass. The roots are
/// `CLAUDE_CONFIG_DIR` when set, otherwise the discovered account roots under
/// `~/.codex-accounts/claude`, `~/.claude`, and `~/.subrouter/codex/claude`.
final class ClaudeTranscriptLookupCache {
    private let homeDirectory: String
    private let fileManager: FileManager
    private var defaultRoots: [String]?
    private var projectDirsByConfigRoot: [String: [String]] = [:]

    init(homeDirectory: String, fileManager: FileManager) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func configRoots(for record: ClaudeTranscriptRecordInput) -> [String] {
        if let configured = ClaudeTranscriptStore.normalizedNonEmptyValue(
            record.claudeConfigDirectory
        ) {
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    configured,
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                ),
            ]
        }

        if let defaultRoots {
            return defaultRoots
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

        defaultRoots = roots
        return roots
    }

    func projectDirs(configRoot: String) -> [String] {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        if let cached = projectDirsByConfigRoot[standardizedRoot] {
            return cached
        }

        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        guard directoryExists(atPath: projectsRoot),
              let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
            projectDirsByConfigRoot[standardizedRoot] = []
            return []
        }

        projectDirsByConfigRoot[standardizedRoot] = projectDirs
        return projectDirs
    }

    private func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

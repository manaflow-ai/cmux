public import Foundation

/// Filesystem discovery for Claude Code session transcripts: enumerates the
/// configured Claude configuration roots and the `*.jsonl` transcript candidates
/// under each root's `projects/` directory.
///
/// This is an instance service, not a static-utility namespace. The three
/// app-side dependencies it needs are injected as closures so the service stays
/// decoupled from higher packages (`ClaudeConfigDirectoryPath`,
/// `ClaudeConfigurationRoot`) and the app-target `RestorableAgentSessionIndex`,
/// and so each can be faked in tests:
///
/// - `preferredConfigDirectoryPath` standardizes a configuration directory path
///   (the app wires this to `ClaudeConfigDirectoryPath.preferredPath`).
/// - `configuredResumeDirectory` returns the resume configuration directory for a
///   standardized config dir, or `nil` when the root is not configured for resume
///   (the app wires this to `ClaudeConfigurationRoot.configuredResumeDirectory`).
/// - `encodeClaudeProjectDir` encodes a cwd into the Claude project directory name
///   (the app wires this to `RestorableAgentSessionIndex.encodeClaudeProjectDir`),
///   single-sourcing the dotted-path encoding (`.` -> `-`) with transcript discovery.
///
/// The FileManager is injected so tests can scope it; production passes
/// `FileManager.default`.
///
/// ```swift
/// let discovery = ClaudeSessionDiscovery(
///     preferredConfigDirectoryPath: { ClaudeConfigDirectoryPath.preferredPath($0, fileManager: $1) },
///     configuredResumeDirectory: { ClaudeConfigurationRoot.configuredResumeDirectory($0, fileManager: $1) },
///     encodeClaudeProjectDir: { RestorableAgentSessionIndex.encodeClaudeProjectDir($0) }
/// )
/// let roots = discovery.sessionRoots()
/// ```
public struct ClaudeSessionDiscovery: Sendable {
    /// A configured Claude configuration root and its (optional) resume directory.
    public struct SessionRoot: Hashable, Sendable {
        public let configDir: String
        public let resumeConfigDirectory: String?

        public init(configDir: String, resumeConfigDirectory: String?) {
            self.configDir = configDir
            self.resumeConfigDirectory = resumeConfigDirectory
        }

        /// The `projects/` subdirectory that holds per-cwd transcript folders.
        public var projectsRoot: String {
            (configDir as NSString).appendingPathComponent("projects")
        }
    }

    /// A candidate `*.jsonl` transcript file discovered under a session root.
    public struct SessionCandidate: Sendable {
        public let url: URL
        public let mtime: Date
        public let dirName: String
        public let resumeConfigDirectory: String?
        public let prefilteredByRipgrep: Bool

        public init(
            url: URL,
            mtime: Date,
            dirName: String,
            resumeConfigDirectory: String?,
            prefilteredByRipgrep: Bool
        ) {
            self.url = url
            self.mtime = mtime
            self.dirName = dirName
            self.resumeConfigDirectory = resumeConfigDirectory
            self.prefilteredByRipgrep = prefilteredByRipgrep
        }
    }

    private let fileManager: FileManager
    private let preferredConfigDirectoryPath: @Sendable (String, FileManager) -> String
    private let configuredResumeDirectory: @Sendable (String, FileManager) -> String?
    private let encodeClaudeProjectDir: @Sendable (String) -> String

    /// Create a discovery service.
    /// - Parameters:
    ///   - fileManager: Filesystem used for all directory/attribute reads.
    ///   - preferredConfigDirectoryPath: Standardizes a raw config dir path.
    ///   - configuredResumeDirectory: Returns the resume config dir for a
    ///     standardized config dir, or `nil` when not configured for resume.
    ///   - encodeClaudeProjectDir: Encodes a cwd into the Claude project dir name.
    public init(
        fileManager: FileManager = .default,
        preferredConfigDirectoryPath: @escaping @Sendable (String, FileManager) -> String,
        configuredResumeDirectory: @escaping @Sendable (String, FileManager) -> String?,
        encodeClaudeProjectDir: @escaping @Sendable (String) -> String
    ) {
        self.fileManager = fileManager
        self.preferredConfigDirectoryPath = preferredConfigDirectoryPath
        self.configuredResumeDirectory = configuredResumeDirectory
        self.encodeClaudeProjectDir = encodeClaudeProjectDir
    }

    /// Enumerate the configured Claude configuration roots, in precedence order:
    /// `CLAUDE_CONFIG_DIR`, then each `~/.codex-accounts/claude/<account>` that is
    /// configured for resume, then `~/.claude`. Roots whose `projects/` directory
    /// is missing are skipped; duplicates (by standardized config dir) are deduped.
    public func sessionRoots() -> [SessionRoot] {
        let fm = fileManager
        var roots: [SessionRoot] = []
        var seen: Set<String> = []

        func appendRoot(_ rawPath: String?, requireConfigured: Bool) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let configDir = (trimmed as NSString).expandingTildeInPath
            let standardized = preferredConfigDirectoryPath(configDir, fm)
            let projectsRoot = (standardized as NSString).appendingPathComponent("projects")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectsRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let resumeConfigDirectory = configuredResumeDirectory(standardized, fm)
            if requireConfigured, resumeConfigDirectory == nil {
                return
            }
            guard seen.insert(standardized).inserted else { return }
            roots.append(
                SessionRoot(
                    configDir: standardized,
                    resumeConfigDirectory: resumeConfigDirectory
                )
            )
        }

        let environmentConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        appendRoot(environmentConfigDir, requireConfigured: false)

        let accountRoot = ("~/.codex-accounts/claude" as NSString).expandingTildeInPath
        if let accountDirs = try? fm.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                appendRoot(
                    (accountRoot as NSString).appendingPathComponent(accountDir),
                    requireConfigured: true
                )
            }
        }

        appendRoot(
            ("~/.claude" as NSString).expandingTildeInPath,
            requireConfigured: false
        )

        return roots
    }

    /// Enumerate the `*.jsonl` transcript candidates under `root`.
    /// - When `cwdFilter` is non-nil: fast path that visits only the single
    ///   encoded project directory for that cwd.
    /// - When `cwdFilter` is nil: visits every project directory under the root.
    /// `prefilteredByRipgrep` is recorded on each candidate so downstream parsing
    /// knows whether the needle was already matched.
    public func enumerateJSONLCandidates(
        root: SessionRoot,
        cwdFilter: String?,
        prefilteredByRipgrep: Bool
    ) -> [SessionCandidate] {
        let fm = fileManager
        var candidates: [SessionCandidate] = []

        func appendJSONLFiles(in dirPath: String, dirName: String) {
            guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
            for name in contents where name.hasSuffix(".jsonl") {
                let filePath = (dirPath as NSString).appendingPathComponent(name)
                let url = URL(fileURLWithPath: filePath)
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                candidates.append(
                    SessionCandidate(
                        url: url,
                        mtime: mtime,
                        dirName: dirName,
                        resumeConfigDirectory: root.resumeConfigDirectory,
                        prefilteredByRipgrep: prefilteredByRipgrep
                    )
                )
            }
        }

        if let cwdFilter {
            // Single-sourced with RestorableAgentSessionIndex so this fast-path cwd filter
            // encodes dotted paths ("." -> "-") identically to the transcript-discovery path.
            let dirName = encodeClaudeProjectDir(cwdFilter)
            let dirPath = (root.projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                appendJSONLFiles(in: dirPath, dirName: dirName)
            }
            return candidates
        }

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: root.projectsRoot) else {
            return candidates
        }
        for dirName in projectDirs {
            let dirPath = (root.projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            appendJSONLFiles(in: dirPath, dirName: dirName)
        }
        return candidates
    }
}

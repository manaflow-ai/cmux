import Foundation

/// A configured Claude Code session root: a `.claude`-style config directory plus
/// the resume config directory used when reopening a transcript. The `projects`
/// subdirectory holds one encoded-cwd folder per project.
struct ClaudeSessionRoot: Hashable {
    let configDir: String
    let resumeConfigDirectory: String?

    var projectsRoot: String {
        (configDir as NSString).appendingPathComponent("projects")
    }

    /// Discover every Claude session root: the `CLAUDE_CONFIG_DIR` override, each
    /// configured `~/.codex-accounts/claude/*` account directory, and `~/.claude`.
    /// Only roots whose `projects` subdirectory exists are returned, de-duplicated
    /// by standardized config path.
    static func discoverAll() -> [ClaudeSessionRoot] {
        let fm = FileManager.default
        var roots: [ClaudeSessionRoot] = []
        var seen: Set<String> = []

        func appendRoot(_ rawPath: String?, requireConfigured: Bool) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let configDir = (trimmed as NSString).expandingTildeInPath
            let standardized = ClaudeConfigDirectoryPath.preferredPath(configDir)
            let projectsRoot = (standardized as NSString).appendingPathComponent("projects")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectsRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let resumeConfigDirectory = ClaudeConfigurationRoot.configuredResumeDirectory(
                standardized,
                fileManager: fm
            )
            if requireConfigured, resumeConfigDirectory == nil {
                return
            }
            guard seen.insert(standardized).inserted else { return }
            roots.append(
                ClaudeSessionRoot(
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
}

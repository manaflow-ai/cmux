import Foundation

/// Per-load memoization of Claude's config roots and their on-disk project
/// directory listings, so a single `RestorableAgentSessionIndex.load` resolves
/// every record's transcript without re-scanning `~/.claude` / `~/.codex-accounts`
/// for each one.
///
/// This is a single-threaded scratch cache: it is created once at the start of a
/// synchronous load, read and written only on that thread, and discarded when the
/// load returns. It never crosses an isolation boundary, so it is a plain class
/// rather than an actor.
public final class ClaudeTranscriptLookupCache {
    private let homeDirectory: String
    private let fileManager: FileManager
    private var defaultRoots: [String]?
    private var projectDirsByConfigRoot: [String: [String]] = [:]

    public init(homeDirectory: String, fileManager: FileManager) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func configRoots(forClaudeConfigDir configDir: String?) -> [String] {
        if let configured = ClaudeTranscriptResolver.normalizedNonEmptyValue(configDir) {
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

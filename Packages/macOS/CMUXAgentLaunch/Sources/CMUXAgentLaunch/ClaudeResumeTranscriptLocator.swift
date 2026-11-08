import Foundation

/// Finds the transcript Claude Code needs to resume a session.
///
/// Claude writes `<config>/projects/<slug>/<id>.jsonl` only after the first
/// message, so a session that was quit before any prompt has nothing to
/// resume and `claude --resume <id>` fails with "No conversation found".
public struct ClaudeResumeTranscriptLocator: Sendable {
    private let homeDirectory: String

    /// Creates a locator that resolves the default config roots under `homeDirectory`.
    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    /// Returns the config roots to search: each configured `CLAUDE_CONFIG_DIR`
    /// first, then the cmux account roots, `~/.claude`, and the legacy
    /// Subrouter root. Duplicates are removed.
    public func configRoots(configuredDirectories: [String]) -> [String] {
        var roots: [String] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        for directory in configuredDirectories {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            appendRoot(ClaudeConfigDirectoryPath.preferredPath(trimmed, homeDirectory: homeDirectory))
        }
        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        if directoryExists(atPath: accountRoot),
           let accountDirectories = try? FileManager.default.contentsOfDirectory(atPath: accountRoot) {
            for accountDirectory in accountDirectories.sorted() {
                appendRoot((accountRoot as NSString).appendingPathComponent(accountDirectory))
            }
        }
        appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
        appendRoot(
            ClaudeConfigDirectoryPath.preferredPath(
                (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
                homeDirectory: homeDirectory
            )
        )
        return roots
    }

    /// Whether a non-empty transcript for `sessionId` exists in any project
    /// under ``configRoots(configuredDirectories:)``.
    public func transcriptExists(sessionId: String, configuredDirectories: [String]) -> Bool {
        let sessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty,
              sessionId != ".",
              sessionId != "..",
              !sessionId.contains("/"),
              !sessionId.contains("\\") else {
            return false
        }
        for root in configRoots(configuredDirectories: configuredDirectories) {
            let projectsRoot = (root as NSString).appendingPathComponent("projects")
            guard directoryExists(atPath: projectsRoot),
                  let projectDirectories = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else {
                continue
            }
            for projectDirectory in projectDirectories {
                let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDirectory)
                let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
                let nestedMessagesPath = (((projectRoot as NSString)
                    .appendingPathComponent(sessionId) as NSString)
                    .appendingPathComponent("messages") as NSString)
                    .appendingPathComponent("\(sessionId).jsonl")
                if regularNonEmptyFileExists(atPath: directPath)
                    || regularNonEmptyFileExists(atPath: nestedMessagesPath) {
                    return true
                }
            }
        }
        return false
    }

    private func regularNonEmptyFileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

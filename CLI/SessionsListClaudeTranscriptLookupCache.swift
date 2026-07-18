import CMUXAgentLaunch
import Foundation

/// Reuses exact Claude transcript lookups across every row in one list or tree invocation.
final class SessionsListClaudeTranscriptLookupCache {
    private let homeDirectory: String
    private let fileManager: FileManager
    private var defaultRoots: [String]?
    private var transcriptPathByProjectRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByProjectRootAndSession: Set<String> = []

    init(homeDirectory: String, fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func configRoots(record: ClaudeHookSessionRecord) -> [String] {
        if let configured = normalized(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            return [
                ClaudeConfigDirectoryPath.preferredPath(
                    expandedPath(configured),
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                ),
            ]
        }

        if let defaultRoots { return defaultRoots }

        var roots: [String] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
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

    func transcriptPath(configRoot: String, projectDirName: String, sessionId: String) -> String? {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        let projectRoot = ((projectsRoot as NSString).appendingPathComponent(projectDirName) as NSString)
            .standardizingPath
        let key = cacheKey(projectRoot, sessionId)
        if let cached = transcriptPathByProjectRootAndSession[key] { return cached }
        if missingTranscriptPathByProjectRootAndSession.contains(key) { return nil }

        let path = transcriptPath(inProjectRoot: projectRoot, sessionId: sessionId)
        if let path {
            transcriptPathByProjectRootAndSession[key] = path
        } else {
            missingTranscriptPathByProjectRootAndSession.insert(key)
        }
        return path
    }

    private func transcriptPath(inProjectRoot projectRoot: String, sessionId: String) -> String? {
        guard directoryExists(atPath: projectRoot) else { return nil }
        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: directPath) { return directPath }

        let nestedMessagesPath = (((projectRoot as NSString)
            .appendingPathComponent(sessionId) as NSString)
            .appendingPathComponent("messages") as NSString)
            .appendingPathComponent("\(sessionId).jsonl")
        if regularNonEmptyFileExists(atPath: nestedMessagesPath) { return nestedMessagesPath }
        return nil
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

    private func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func expandedPath(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }

    private func cacheKey(_ prefix: String, _ sessionId: String) -> String {
        prefix + "\u{0}" + sessionId
    }
}

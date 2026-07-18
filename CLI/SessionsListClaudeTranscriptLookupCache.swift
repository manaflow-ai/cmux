import CMUXAgentLaunch
import Foundation

/// Reuses Claude project-directory indexes across every row in one list or tree invocation.
final class SessionsListClaudeTranscriptLookupCache {
    private struct ConfigurationIndex {
        var projectRootsByWorkflowSession: [String: [String]]
        var transcriptPathBySession: [String: String]
    }

    private let homeDirectory: String
    private let fileManager: FileManager
    private var defaultRoots: [String]?
    private var projectDirsByConfigRoot: [String: [String]] = [:]
    private var transcriptPathByProjectRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByProjectRootAndSession: Set<String> = []
    private var transcriptPathByConfigRootAndSession: [String: String] = [:]
    private var missingTranscriptPathByConfigRootAndSession: Set<String> = []
    private var configurationIndexByRoot: [String: ConfigurationIndex] = [:]
    private var workflowTranscriptsByProjectRoot: [String: [(sessionId: String, path: String)]] = [:]

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

    func transcriptPathInAnyProject(configRoot: String, sessionId: String) -> String? {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        let key = cacheKey(standardizedRoot, sessionId)
        if let cached = transcriptPathByConfigRootAndSession[key] { return cached }
        if missingTranscriptPathByConfigRootAndSession.contains(key) { return nil }

        if let path = configurationIndex(configRoot: standardizedRoot)
            .transcriptPathBySession[sessionId] {
            transcriptPathByConfigRootAndSession[key] = path
            return path
        }
        missingTranscriptPathByConfigRootAndSession.insert(key)
        return nil
    }

    func workflowProjectRoots(configRoot: String, sessionId: String) -> [String] {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        return configurationIndex(configRoot: standardizedRoot)
            .projectRootsByWorkflowSession[sessionId] ?? []
    }

    func singleSiblingTranscript(
        projectRoots: [String],
        excludingSessionId excludedSessionId: String
    ) -> (sessionId: String, path: String)? {
        var match: (sessionId: String, path: String)?
        for projectRoot in projectRoots {
            for candidate in workflowTranscripts(inProjectRoot: projectRoot) {
                guard candidate.sessionId != excludedSessionId else { continue }
                guard match == nil else { return nil }
                match = candidate
            }
        }
        return match
    }

    func projectDirs(configRoot: String) -> [String] {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        if let cached = projectDirsByConfigRoot[standardizedRoot] { return cached }
        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        guard directoryExists(atPath: projectsRoot),
              let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsRoot) else {
            projectDirsByConfigRoot[standardizedRoot] = []
            return []
        }
        projectDirsByConfigRoot[standardizedRoot] = projectDirs
        return projectDirs
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

    private func configurationIndex(configRoot: String) -> ConfigurationIndex {
        let standardizedRoot = (configRoot as NSString).standardizingPath
        if let cached = configurationIndexByRoot[standardizedRoot] { return cached }

        let projectsRoot = (standardizedRoot as NSString).appendingPathComponent("projects")
        var projectRootsByWorkflowSession: [String: [String]] = [:]
        var transcriptPathBySession: [String: String] = [:]
        for projectDir in projectDirs(configRoot: standardizedRoot) {
            let projectRoot = (projectsRoot as NSString).appendingPathComponent(projectDir)
            guard directoryExists(atPath: projectRoot),
                  let children = try? fileManager.contentsOfDirectory(atPath: projectRoot) else {
                continue
            }

            // Preserve the old lookup preference: a direct transcript in one
            // project wins over that project's nested messages transcript.
            for child in children where child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard transcriptPathBySession[sessionId] == nil else { continue }
                let path = (projectRoot as NSString).appendingPathComponent(child)
                if regularNonEmptyFileExists(atPath: path) {
                    transcriptPathBySession[sessionId] = path
                }
            }

            for child in children {
                let childPath = (projectRoot as NSString).appendingPathComponent(child)
                guard directoryExists(atPath: childPath) else { continue }
                projectRootsByWorkflowSession[child, default: []].append(projectRoot)
                guard transcriptPathBySession[child] == nil else { continue }
                let nestedPath = (((childPath as NSString)
                    .appendingPathComponent("messages") as NSString)
                    .appendingPathComponent("\(child).jsonl"))
                if regularNonEmptyFileExists(atPath: nestedPath) {
                    transcriptPathBySession[child] = nestedPath
                }
            }
        }
        let index = ConfigurationIndex(
            projectRootsByWorkflowSession: projectRootsByWorkflowSession,
            transcriptPathBySession: transcriptPathBySession
        )
        configurationIndexByRoot[standardizedRoot] = index
        return index
    }

    private func workflowTranscripts(inProjectRoot projectRoot: String) -> [(sessionId: String, path: String)] {
        let standardizedRoot = (projectRoot as NSString).standardizingPath
        if let cached = workflowTranscriptsByProjectRoot[standardizedRoot] { return cached }
        var matches: [(sessionId: String, path: String)] = []
        collectWorkflowTranscripts(
            inDirectory: standardizedRoot,
            remainingDirectoryDepth: 4,
            matches: &matches
        )
        workflowTranscriptsByProjectRoot[standardizedRoot] = matches
        return matches
    }

    private func collectWorkflowTranscripts(
        inDirectory directory: String,
        remainingDirectoryDepth: Int,
        matches: inout [(sessionId: String, path: String)]
    ) {
        guard directoryExists(atPath: directory),
              let children = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return
        }
        for child in children {
            let childPath = (directory as NSString).appendingPathComponent(child)
            if child.hasSuffix(".jsonl") {
                let sessionId = String(child.dropLast(".jsonl".count))
                guard !sessionId.isEmpty,
                      sessionId != ".",
                      sessionId != "..",
                      sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil,
                      regularNonEmptyFileExists(atPath: childPath) else {
                    continue
                }
                matches.append((sessionId, childPath))
            } else if remainingDirectoryDepth > 0 {
                collectWorkflowTranscripts(
                    inDirectory: childPath,
                    remainingDirectoryDepth: remainingDirectoryDepth - 1,
                    matches: &matches
                )
            }
        }
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

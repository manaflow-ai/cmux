import CMUXAgentLaunch
import Foundation

struct ClaudeTranscriptSeeder {
    let fileManager: FileManager
    let homeDirectory: String

    init(fileManager: FileManager = .default, homeDirectory: String = NSHomeDirectory()) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    @discardableResult
    func seedTranscriptIfNeeded(
        sessionId: String,
        targetWorkingDirectory: String?,
        sourceWorkingDirectory: String?,
        environment: [String: String]?
    ) -> Bool {
        guard Self.isSafeSessionId(sessionId),
              let targetWorkingDirectory = Self.normalized(targetWorkingDirectory) else {
            return false
        }

        for configRoot in configRoots(environment: environment) {
            let targetProjectDirectory = projectDirectory(configRoot: configRoot, cwd: targetWorkingDirectory)
            if transcriptURL(inProjectDirectory: targetProjectDirectory, sessionId: sessionId) != nil {
                return false
            }
            guard let sourceProjectDirectory = sourceProjectDirectory(
                sessionId: sessionId,
                configRoot: configRoot,
                targetProjectDirectory: targetProjectDirectory,
                sourceWorkingDirectory: sourceWorkingDirectory
            ),
                  let sourceTranscript = transcriptURL(
                      inProjectDirectory: sourceProjectDirectory,
                      sessionId: sessionId
                  ) else {
                continue
            }
            return copyTranscript(
                sourceTranscript: sourceTranscript,
                sourceProjectDirectory: sourceProjectDirectory,
                targetProjectDirectory: targetProjectDirectory,
                sessionId: sessionId
            )
        }
        return false
    }

    static func encodedProjectDirectoryName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    func transcriptURL(inProjectDirectory projectDirectory: URL, sessionId: String) -> URL? {
        guard Self.isSafeSessionId(sessionId) else { return nil }

        let directURL = projectDirectory.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        if regularNonEmptyFileExists(at: directURL) {
            return directURL
        }

        let nestedMessagesURL = projectDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        if regularNonEmptyFileExists(at: nestedMessagesURL) {
            return nestedMessagesURL
        }
        return nil
    }

    private func sourceProjectDirectory(
        sessionId: String,
        configRoot: URL,
        targetProjectDirectory: URL,
        sourceWorkingDirectory: String?
    ) -> URL? {
        let targetPath = targetProjectDirectory.standardizedFileURL.path
        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendCandidate(_ candidate: URL) {
            let path = candidate.standardizedFileURL.path
            guard path != targetPath, seen.insert(path).inserted else { return }
            candidates.append(candidate)
        }

        if let sourceWorkingDirectory = Self.normalized(sourceWorkingDirectory) {
            appendCandidate(projectDirectory(configRoot: configRoot, cwd: sourceWorkingDirectory))
        }

        for projectDirectory in projectDirectories(configRoot: configRoot) {
            appendCandidate(projectDirectory)
        }

        return candidates.first {
            transcriptURL(inProjectDirectory: $0, sessionId: sessionId) != nil
        }
    }

    private func copyTranscript(
        sourceTranscript: URL,
        sourceProjectDirectory: URL,
        targetProjectDirectory: URL,
        sessionId: String
    ) -> Bool {
        let targetTranscript = targetProjectDirectory.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        do {
            try fileManager.createDirectory(at: targetProjectDirectory, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: targetTranscript.path) else {
                return false
            }
            try fileManager.copyItem(at: sourceTranscript, to: targetTranscript)
            copySidecarDirectoryIfNeeded(
                sourceProjectDirectory: sourceProjectDirectory,
                targetProjectDirectory: targetProjectDirectory,
                sessionId: sessionId
            )
            return true
        } catch {
            return false
        }
    }

    private func copySidecarDirectoryIfNeeded(
        sourceProjectDirectory: URL,
        targetProjectDirectory: URL,
        sessionId: String
    ) {
        let sourceSidecar = sourceProjectDirectory.appendingPathComponent(sessionId, isDirectory: true)
        guard directoryExists(at: sourceSidecar) else { return }

        let targetSidecar = targetProjectDirectory.appendingPathComponent(sessionId, isDirectory: true)
        guard !fileManager.fileExists(atPath: targetSidecar.path) else { return }
        try? fileManager.copyItem(at: sourceSidecar, to: targetSidecar)
    }

    private func projectDirectory(configRoot: URL, cwd: String) -> URL {
        configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(Self.encodedProjectDirectoryName(for: cwd), isDirectory: true)
    }

    private func projectDirectories(configRoot: URL) -> [URL] {
        let projectsRoot = configRoot.appendingPathComponent("projects", isDirectory: true)
        guard directoryExists(at: projectsRoot),
              let names = try? fileManager.contentsOfDirectory(atPath: projectsRoot.path) else {
            return []
        }
        return names.sorted().map {
            projectsRoot.appendingPathComponent($0, isDirectory: true)
        }
    }

    private func configRoots(environment: [String: String]?) -> [URL] {
        if let configured = environment.flatMap({ Self.normalized($0["CLAUDE_CONFIG_DIR"]) }) {
            return [
                URL(fileURLWithPath: ClaudeConfigDirectoryPath.preferredPath(
                    configured,
                    fileManager: fileManager,
                    homeDirectory: homeDirectory
                ), isDirectory: true).standardizedFileURL,
            ]
        }

        var roots: [URL] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else { return }
            roots.append(url)
        }

        let home = (homeDirectory as NSString).expandingTildeInPath
        let accountRoot = (home as NSString).appendingPathComponent(".codex-accounts/claude")
        if directoryExists(at: URL(fileURLWithPath: accountRoot, isDirectory: true)),
           let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                appendRoot((accountRoot as NSString).appendingPathComponent(accountDir))
            }
        }
        appendRoot((home as NSString).appendingPathComponent(".claude"))
        appendRoot(ClaudeConfigDirectoryPath.preferredPath(
            (home as NSString).appendingPathComponent(".subrouter/codex/claude"),
            fileManager: fileManager,
            homeDirectory: homeDirectory
        ))
        return roots
    }

    private func regularNonEmptyFileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isSafeSessionId(_ sessionId: String) -> Bool {
        sessionId.range(of: #"[\\/]"#, options: .regularExpression) == nil
            && !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
    }

    private static func normalized(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}

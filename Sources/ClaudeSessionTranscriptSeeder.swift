import Darwin
import Foundation

/// Seeds a Claude Code session transcript into the project dir of a new working
/// directory before a `claude --resume <id>` launch. Claude scopes resume
/// lookups to `<config>/projects/<encoded-cwd>/`, so forking or restoring a
/// conversation into a different directory fails with "No conversation found"
/// unless the transcript is copied there first.
/// https://github.com/manaflow-ai/cmux/issues/5941
enum ClaudeSessionTranscriptSeeder {
    /// Claude Code project dir name for a working directory: the absolute path
    /// with every non-alphanumeric character replaced by `-`. Claude resolves
    /// symlinks before encoding (Node `process.cwd()`), so `/tmp/x` is stored
    /// as `-private-tmp-x`.
    static func encodedProjectDirName(forWorkingDirectory workingDirectory: String) -> String {
        let resolved = symlinkResolvedAbsolutePath(workingDirectory)
        return String(resolved.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    /// Config dirs to search for the session transcript, most specific first:
    /// the launch snapshot's captured CLAUDE_CONFIG_DIR (re-applied via `env`
    /// on resume, so it is the dir the resumed claude will actually read),
    /// then this process's CLAUDE_CONFIG_DIR, then `~/.claude`.
    static func defaultConfigDirCandidates(
        launchEnvironment: [String: String]?,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var seenPaths = Set<String>()
        var candidates: [URL] = []
        func add(_ path: String?) {
            guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let url = URL(fileURLWithPath: path)
            if seenPaths.insert(url.standardizedFileURL.path).inserted {
                candidates.append(url)
            }
        }
        add(launchEnvironment?["CLAUDE_CONFIG_DIR"])
        add(processEnvironment["CLAUDE_CONFIG_DIR"])
        add(homeDirectory.appendingPathComponent(".claude").path)
        return candidates
    }

    /// Copies `projects/<source>/<id>.jsonl` (and the optional `<id>/` sidecar
    /// dir) into `projects/<encoded-target-cwd>/` inside the first candidate
    /// config dir that has the transcript. No-op when the target project dir
    /// already has it. A copy rather than a hardlink so concurrent resumes of
    /// the same id from two cwds cannot interleave appends into one inode.
    /// Returns true when the transcript is present in the target project dir
    /// after the call. Best-effort: copy failures must never block the launch.
    @discardableResult
    static func seedIfNeeded(
        sessionId: String,
        targetWorkingDirectory: String,
        configDirCandidates: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        guard isPlausibleSessionId(sessionId) else { return false }
        let targetName = encodedProjectDirName(forWorkingDirectory: targetWorkingDirectory)
        guard !targetName.isEmpty else { return false }
        let transcriptName = "\(sessionId).jsonl"

        for configDir in configDirCandidates {
            let projects = configDir.appendingPathComponent("projects")
            let targetDir = projects.appendingPathComponent(targetName)
            let targetTranscript = targetDir.appendingPathComponent(transcriptName)
            if fileManager.fileExists(atPath: targetTranscript.path) {
                return true
            }
            guard let projectDirs = try? fileManager.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil) else {
                continue
            }
            for projectDir in projectDirs where projectDir.lastPathComponent != targetName {
                let sourceTranscript = projectDir.appendingPathComponent(transcriptName)
                guard isFile(at: sourceTranscript, fileManager: fileManager) else { continue }
                do {
                    try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: sourceTranscript, to: targetTranscript)
                } catch {
                    continue
                }
                let sidecar = projectDir.appendingPathComponent(sessionId)
                let sidecarTarget = targetDir.appendingPathComponent(sessionId)
                if isDirectory(at: sidecar, fileManager: fileManager),
                   !fileManager.fileExists(atPath: sidecarTarget.path) {
                    try? fileManager.copyItem(at: sidecar, to: sidecarTarget)
                }
                return true
            }
        }
        return false
    }

    /// Session ids are UUID-shaped (hex + dashes). Refusing anything else keeps
    /// untrusted ids from path-escaping the projects dir.
    private static func isPlausibleSessionId(_ sessionId: String) -> Bool {
        !sessionId.isEmpty && sessionId.allSatisfy { character in
            character == "-" || (character.isASCII && (character.isLetter || character.isNumber))
        }
    }

    private static func isFile(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isDirectory(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// realpath(3)-style resolution matching Node's `process.cwd()` (keeps the
    /// `/private` prefix, unlike `URL.resolvingSymlinksInPath()` which strips
    /// it). When the full path does not exist, resolves the deepest existing
    /// ancestor and reattaches the remaining components.
    private static func symlinkResolvedAbsolutePath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardized.path
        var current = standardized
        var unresolvedComponents: [String] = []
        while !current.isEmpty, current != "/" {
            if let resolved = realpathString(current) {
                return unresolvedComponents.reversed().reduce(resolved) { $0 + "/" + $1 }
            }
            let url = URL(fileURLWithPath: current)
            unresolvedComponents.append(url.lastPathComponent)
            current = url.deletingLastPathComponent().path
        }
        return standardized
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

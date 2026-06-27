import Foundation
import CmuxFoundation

/// Runs `git status --porcelain` (locally or over SSH) and parses the output
/// into a path-to-``GitFileStatus`` map for the file explorer.
///
/// It is a stateless `Sendable` value, not an `actor`, because it has no mutable
/// shared state for an actor to protect — every read is a pure function of its
/// arguments. Each entrypoint spawns a `git`/`ssh` process and parses the
/// result; callers run it off the main thread themselves (the file explorer
/// dispatches it onto a utility global queue), so the methods stay synchronous
/// and blocking to preserve that threading exactly.
///
/// ```swift
/// let git = GitStatusService()
/// let statuses = git.fetchStatus(directory: "/path/to/checkout")
/// ```
public struct GitStatusService: Sendable {
    /// Creates a git-status service.
    public init() {}

    /// Reads the working-tree status of `directory`'s enclosing repository by
    /// spawning a local `git status --porcelain`.
    ///
    /// - Parameter directory: An absolute path to inspect. Only entries at or
    ///   below this path are returned.
    /// - Returns: A map from absolute path to ``GitFileStatus``, with parent
    ///   directories of changed files marked with a coarse status. Empty when
    ///   `directory` is not inside a git repository.
    public func fetchStatus(directory: String) -> [String: GitFileStatus] {
        guard let repoRoot = Self.gitRepoRoot(for: directory) else { return [:] }
        return Self.parseGitStatus(
            output: Self.runGit(in: repoRoot, arguments: ["status", "--porcelain"]),
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    /// Reads the working-tree status of a remote `directory` by running
    /// `git status --porcelain` over SSH.
    ///
    /// - Parameters:
    ///   - directory: The absolute remote path to inspect.
    ///   - destination: The SSH destination (`user@host` or a config alias).
    ///   - port: An optional SSH port.
    ///   - identityFile: An optional identity file path.
    ///   - sshOptions: Extra `-o` options to pass to `ssh`.
    /// - Returns: A map from absolute remote path to ``GitFileStatus``. Empty
    ///   when the remote directory is not inside a git repository or the SSH
    ///   command fails.
    public func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(escapedDir)' 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && echo '---GIT_STATUS---' && git status --porcelain 2>/dev/null"
        guard let output = Self.runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return [:] }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return [:] }
        let repoRoot = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.parseGitStatus(output: parts[1], repoRoot: repoRoot, explorerRoot: directory)
    }

    private static func parseGitStatus(
        output: String?, repoRoot: String, explorerRoot: String
    ) -> [String: GitFileStatus] {
        guard let output, !output.isEmpty else { return [:] }
        var statusMap: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")

            if path.contains(" -> ") {
                path = String(path.split(separator: " -> ").last ?? Substring(path))
            }

            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else { continue }

            let absolutePath = repoRoot.hasSuffix("/") ? repoRoot + path : repoRoot + "/" + path
            guard absolutePath.hasPrefix(explorerRoot) else { continue }

            statusMap[absolutePath] = status
            markParentDirectories(absolutePath: absolutePath, explorerRoot: explorerRoot, status: status, in: &statusMap)
        }
        return statusMap
    }

    private static func parseStatusChars(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "A" || workTree == "A" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    private static func markParentDirectories(
        absolutePath: String, explorerRoot: String,
        status: GitFileStatus, in map: inout [String: GitFileStatus]
    ) {
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while current.hasPrefix(explorerRoot) && current != explorerRoot {
            if map[current] == nil {
                map[current] = dirStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func gitRepoRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runSSH(
        command: String, destination: String,
        port: Int?, identityFile: String?, sshOptions: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = []
        if let port { args += ["-p", String(port)] }
        if let identityFile { args += ["-i", identityFile] }
        for option in sshOptions { args += ["-o", option] }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [destination, command]
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - Async offload

extension GitStatusService {
    /// Computes local working-tree status off the main thread.
    ///
    /// The synchronous ``fetchStatus(directory:)`` blocks while it spawns and
    /// waits on `git`; this overload runs that blocking work on a utility-QoS
    /// global queue and resumes with the result, so callers no longer manage the
    /// background dispatch themselves.
    ///
    /// - Parameter directory: An absolute path to inspect.
    /// - Returns: The same path-to-``GitFileStatus`` map as the synchronous call.
    public func fetchStatus(directory: String) async -> [String: GitFileStatus] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.fetchStatus(directory: directory))
            }
        }
    }

    /// Computes remote working-tree status off the main thread.
    ///
    /// The blocking `ssh`/`git` work of ``fetchStatusSSH(directory:destination:port:identityFile:sshOptions:)``
    /// runs on a utility-QoS global queue, matching the threading the file
    /// explorer previously arranged inline.
    ///
    /// - Parameters:
    ///   - directory: The absolute remote path to inspect.
    ///   - destination: The SSH destination (`user@host` or a config alias).
    ///   - port: An optional SSH port.
    ///   - identityFile: An optional identity file path.
    ///   - sshOptions: Extra `-o` options to pass to `ssh`.
    /// - Returns: The same path-to-``GitFileStatus`` map as the synchronous call.
    public func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) async -> [String: GitFileStatus] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.fetchStatusSSH(
                        directory: directory, destination: destination, port: port,
                        identityFile: identityFile, sshOptions: sshOptions
                    )
                )
            }
        }
    }
}

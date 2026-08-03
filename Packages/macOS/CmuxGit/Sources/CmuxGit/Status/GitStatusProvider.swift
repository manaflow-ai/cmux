public import CmuxFoundation
public import Foundation

/// A working-tree status reported by `git status --porcelain`.
public enum GitFileStatus: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
}

/// Runs non-locking `git status --porcelain` queries and maps their results to
/// absolute paths rooted at the requested file-explorer directory.
public struct GitStatusProvider: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"
    private static let nonLockingRemoteGitCommand =
        "env \(nonLockingGitEnvironmentKey)=\(nonLockingGitEnvironmentValue) git"

    private let gitExecutableURL: URL
    private let sshExecutableURL: URL
    private let commandRunner: any CommandRunning
    private let processTimeout: TimeInterval

    /// Creates a provider with injectable process dependencies.
    public init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: (any CommandRunning)? = nil,
        processTimeout: TimeInterval = 5
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.sshExecutableURL = sshExecutableURL
        if let commandRunner {
            self.commandRunner = commandRunner
        } else {
            var nonLockingEnvironment = environment
            nonLockingEnvironment[Self.nonLockingGitEnvironmentKey] = Self.nonLockingGitEnvironmentValue
            self.commandRunner = CommandRunner(
                environment: nonLockingEnvironment,
                bundledBinPath: nil,
                fallbackSearchDirectories: []
            )
        }
        self.processTimeout = max(0, processTimeout)
    }

    /// Fetches local working-tree status, preserving the prior snapshot when
    /// repository discovery or `git status` fails transiently.
    public func fetchStatus(
        directory: String,
        preserving previousStatus: [String: GitFileStatus] = [:]
    ) async -> [String: GitFileStatus] {
        guard let repoRoot = await gitRepoRoot(for: directory),
              let output = await runGit(
                  in: repoRoot,
                  arguments: ["status", "--porcelain=v1", "-z"]
              ) else {
            return previousStatus
        }
        return parseGitStatus(
            output: output,
            repoRoot: repoRoot,
            explorerRoot: directory,
            resolvesLocalSymlinks: true
        )
    }

    /// Fetches working-tree status over SSH, preserving the prior snapshot
    /// when the remote command or response framing fails transiently.
    public func fetchStatusSSH(
        directory: String,
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        preserving previousStatus: [String: GitFileStatus] = [:]
    ) async -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let command = [
            "cd '\(escapedDir)' 2>/dev/null",
            "\(Self.nonLockingRemoteGitCommand) rev-parse --show-toplevel 2>/dev/null",
            "printf '\\000'",
            "\(Self.nonLockingRemoteGitCommand) status --porcelain=v1 -z 2>/dev/null",
        ].joined(separator: " && ")
        guard let output = await runSSH(
            command: command,
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions
        ) else {
            return previousStatus
        }

        guard let separatorIndex = output.firstIndex(of: "\0") else {
            return previousStatus
        }
        let repoRoot = output[..<separatorIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusStartIndex = output.index(after: separatorIndex)
        let statusOutput = String(output[statusStartIndex...])
        return parseGitStatus(
            output: statusOutput,
            repoRoot: repoRoot,
            explorerRoot: directory,
            resolvesLocalSymlinks: false
        )
    }

    private func parseGitStatus(
        output: String,
        repoRoot: String,
        explorerRoot: String,
        resolvesLocalSymlinks: Bool
    ) -> [String: GitFileStatus] {
        guard !output.isEmpty else { return [:] }
        var statusMap: [String: GitFileStatus] = [:]
        let outputExplorerRoot = Self.standardizedPath(explorerRoot)
        let comparisonRepoRoot = resolvesLocalSymlinks
            ? Self.resolvedPath(repoRoot)
            : Self.standardizedPath(repoRoot)
        let comparisonExplorerRoot = resolvesLocalSymlinks
            ? Self.resolvedPath(explorerRoot)
            : outputExplorerRoot
        guard Self.relativePath(comparisonExplorerRoot, within: comparisonRepoRoot) != nil else {
            return [:]
        }
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)

        var entryIndex = 0
        while entryIndex < entries.count {
            let entry = entries[entryIndex]
            guard entry.count >= 4 else {
                entryIndex += 1
                continue
            }
            let indexStatus = entry[entry.startIndex]
            let workTreeStatus = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            let usesSecondPath = Self.statusUsesSecondPath(index: indexStatus, workTree: workTreeStatus)
            entryIndex += usesSecondPath ? 2 : 1
            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else {
                continue
            }

            let comparisonAbsolutePath = Self.absolutePath(
                base: comparisonRepoRoot,
                relativePath: path
            )
            guard let explorerRelativePath = Self.relativePath(
                comparisonAbsolutePath,
                within: comparisonExplorerRoot
            ) else {
                continue
            }
            let absolutePath = Self.absolutePath(
                base: outputExplorerRoot,
                relativePath: explorerRelativePath
            )

            statusMap[absolutePath] = status
            markParentDirectories(
                absolutePath: absolutePath,
                explorerRoot: outputExplorerRoot,
                status: status,
                in: &statusMap
            )
        }
        return statusMap
    }

    private func parseStatusChars(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "U" || workTree == "U" { return .modified }
        if index == "T" || workTree == "T" { return .modified }
        if index == "A" || workTree == "A" { return .added }
        if index == "C" || workTree == "C" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    private func markParentDirectories(
        absolutePath: String,
        explorerRoot: String,
        status: GitFileStatus,
        in map: inout [String: GitFileStatus]
    ) {
        let directoryStatus: GitFileStatus = status == .untracked ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while Self.path(current, isContainedIn: explorerRoot), current != explorerRoot {
            if map[current] == nil {
                map[current] = directoryStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func statusUsesSecondPath(index: Character, workTree: Character) -> Bool {
        index == "R" || workTree == "R" || index == "C" || workTree == "C"
    }

    private static func absolutePath(base: String, relativePath: String) -> String {
        guard !relativePath.isEmpty else { return base }
        return base == "/" ? "/" + relativePath : base + "/" + relativePath
    }

    private static func path(_ path: String, isContainedIn root: String) -> Bool {
        relativePath(path, within: root) != nil
    }

    private static func relativePath(_ path: String, within root: String) -> String? {
        let normalizedPath = pathWithoutTrailingSlashes(path)
        let normalizedRoot = pathWithoutTrailingSlashes(root)
        if normalizedPath == normalizedRoot { return "" }
        if normalizedRoot == "/" {
            guard normalizedPath.hasPrefix("/") else { return nil }
            return String(normalizedPath.dropFirst())
        }
        let rootPrefix = normalizedRoot + "/"
        guard normalizedPath.hasPrefix(rootPrefix) else { return nil }
        return String(normalizedPath.dropFirst(rootPrefix.count))
    }

    private static func standardizedPath(_ path: String) -> String {
        pathWithoutTrailingSlashes(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    private static func resolvedPath(_ path: String) -> String {
        pathWithoutTrailingSlashes(
            URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )
    }

    private static func pathWithoutTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func gitRepoRoot(for directory: String) async -> String? {
        await runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(in directory: String, arguments: [String]) async -> String? {
        await commandRunner.runStandardOutput(
            directory: directory,
            executable: gitExecutableURL.path,
            arguments: arguments,
            timeout: processTimeout
        )
    }

    private func runSSH(
        command: String,
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String]
    ) async -> String? {
        // A positional command conflicts with a host-configured RemoteCommand.
        var arguments = SSHHostConfiguredRemoteCommand().overrideArguments
        if let port { arguments += ["-p", String(port)] }
        if let identityFile { arguments += ["-i", identityFile] }
        for option in sshOptions { arguments += ["-o", option] }
        arguments += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        arguments += [destination, command]
        return await commandRunner.runStandardOutput(
            directory: "/",
            executable: sshExecutableURL.path,
            arguments: arguments,
            timeout: processTimeout
        )
    }
}

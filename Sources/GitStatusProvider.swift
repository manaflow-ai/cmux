import CmuxFoundation
import Foundation

/// Runs non-locking `git status --porcelain` and parses results into a path-to-status map.
struct GitStatusProvider: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"
    private static let nonLockingRemoteGitCommand = "env \(nonLockingGitEnvironmentKey)=\(nonLockingGitEnvironmentValue) git"

    private let gitExecutableURL: URL
    private let sshExecutableURL: URL
    private let environment: [String: String]

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.sshExecutableURL = sshExecutableURL
        self.environment = environment
    }

    func fetchStatus(directory: String) -> [String: GitFileStatus] {
        guard let repoRoot = gitRepoRoot(for: directory) else { return [:] }
        return parseGitStatus(
            output: runGit(in: repoRoot, arguments: ["status", "--porcelain=v1", "-z"]),
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = [
            "cd '\(escapedDir)' 2>/dev/null",
            "\(Self.nonLockingRemoteGitCommand) rev-parse --show-toplevel 2>/dev/null",
            "echo '---GIT_STATUS---'",
            "\(Self.nonLockingRemoteGitCommand) status --porcelain=v1 -z 2>/dev/null",
        ].joined(separator: " && ")
        guard let output = runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return [:] }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return [:] }
        let repoRoot = parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return parseGitStatus(output: parts[1], repoRoot: repoRoot, explorerRoot: directory)
    }

    private func parseGitStatus(
        output: String?, repoRoot: String, explorerRoot: String
    ) -> [String: GitFileStatus] {
        guard let output, !output.isEmpty else { return [:] }
        var statusMap: [String: GitFileStatus] = [:]
        let normalizedRepoRoot = Self.pathWithoutTrailingSlashes(repoRoot)
        let normalizedExplorerRoot = Self.pathWithoutTrailingSlashes(explorerRoot)
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
            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else { continue }

            let absolutePath = Self.absolutePath(repoRoot: normalizedRepoRoot, relativePath: path)
            guard Self.path(absolutePath, isContainedIn: normalizedExplorerRoot) else { continue }

            statusMap[absolutePath] = status
            markParentDirectories(
                absolutePath: absolutePath,
                explorerRoot: normalizedExplorerRoot,
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
        absolutePath: String, explorerRoot: String,
        status: GitFileStatus, in map: inout [String: GitFileStatus]
    ) {
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while Self.path(current, isContainedIn: explorerRoot) && current != explorerRoot {
            if map[current] == nil {
                map[current] = dirStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func statusUsesSecondPath(index: Character, workTree: Character) -> Bool {
        index == "R" || workTree == "R" || index == "C" || workTree == "C"
    }

    private static func absolutePath(repoRoot: String, relativePath: String) -> String {
        repoRoot == "/" ? "/" + relativePath : repoRoot + "/" + relativePath
    }

    private static func path(_ path: String, isContainedIn root: String) -> Bool {
        let normalizedPath = pathWithoutTrailingSlashes(path)
        let normalizedRoot = pathWithoutTrailingSlashes(root)
        if normalizedPath == normalizedRoot { return true }
        if normalizedRoot == "/" { return normalizedPath.hasPrefix("/") }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private static func pathWithoutTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func gitRepoRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = nonLockingGitEnvironment()
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

    private func nonLockingGitEnvironment() -> [String: String] {
        var environment = environment
        environment[Self.nonLockingGitEnvironmentKey] = Self.nonLockingGitEnvironmentValue
        return environment
    }

    private func runSSH(
        command: String, destination: String,
        port: Int?, identityFile: String?, sshOptions: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = sshExecutableURL
        // The positional command conflicts with a host-configured
        // RemoteCommand unless overridden (issue #7246).
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
        if let port { args += ["-p", String(port)] }
        if let identityFile { args += ["-i", identityFile] }
        for option in sshOptions { args += ["-o", option] }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [destination, command]
        process.arguments = args
        process.environment = environment
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

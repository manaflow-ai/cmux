import Foundation

// MARK: - Git Status

enum GitFileStatus {
    case modified, added, deleted, renamed, untracked
}

/// Runs `git status --porcelain` and parses results into a path-to-status map.
enum GitStatusProvider {

    static func fetchStatus(directory: String) -> [String: GitFileStatus] {
        guard let repoRoot = gitRepoRoot(for: directory) else { return [:] }
        return parseGitStatus(
            output: runGit(in: repoRoot, arguments: ["status", "--porcelain"]),
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    static func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        // GIT_OPTIONAL_LOCKS=0 rather than --no-optional-locks: remote hosts
        // with git < 2.15 reject the unknown flag but ignore the env var.
        let cmd = "cd '\(escapedDir)' 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && echo '---GIT_STATUS---' && GIT_OPTIONAL_LOCKS=0 git status --porcelain 2>/dev/null"
        guard let output = runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return [:] }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return [:] }
        let repoRoot = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return parseGitStatus(output: parts[1], repoRoot: repoRoot, explorerRoot: directory)
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
        // Observing a repo must never take .git/index.lock: a bare `git status`
        // opportunistically rewrites the index under that lock and makes the
        // user's own rebase/commit fail with "index.lock: File exists" (#4779).
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GIT_OPTIONAL_LOCKS": "0"]) { _, new in new }
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

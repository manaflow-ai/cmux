import Foundation

/// Git file status from `git status --porcelain` output.
enum GitFileStatus {
    case modified
    case added
    case deleted
    case renamed
    case untracked
}

/// Runs `git status` and parses results into a path-to-status map.
enum GitStatusProvider {

    /// Fetch git status for all files in the given directory.
    /// Returns [relativePath: GitFileStatus] where paths are relative to the git repo root.
    /// Returns empty dictionary if not a git repo or git is unavailable.
    static func fetchStatus(in directory: URL) -> [String: GitFileStatus] {
        guard let repoRoot = gitRepoRoot(for: directory) else { return [:] }
        guard let output = runGit(in: repoRoot, arguments: ["status", "--porcelain"]) else { return [:] }

        var statusMap: [String: GitFileStatus] = [:]
        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            let path = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")  // git quotes paths with special chars

            // Handle renames: "R  old -> new"
            let effectivePath: String
            if path.contains(" -> ") {
                effectivePath = String(path.split(separator: " -> ").last ?? Substring(path))
            } else {
                effectivePath = path
            }

            // Make path relative to directory (not repo root) for matching with node.id
            let repoRootPath = repoRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let dirPath = directory.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relativePath: String
            if dirPath != repoRootPath {
                let prefix = dirPath.replacingOccurrences(of: repoRootPath, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if effectivePath.hasPrefix(prefix + "/") {
                    relativePath = "/" + String(effectivePath.dropFirst(prefix.count + 1))
                } else {
                    // File is outside our directory scope
                    continue
                }
            } else {
                relativePath = "/" + effectivePath
            }

            let status = parseStatus(index: indexStatus, workTree: workTreeStatus)
            if let status {
                statusMap[relativePath] = status
                // Also mark parent directories
                markParentDirectories(path: relativePath, status: status, in: &statusMap)
            }
        }
        return statusMap
    }

    /// Get the git repository root for a directory.
    private static func gitRepoRoot(for directory: URL) -> String? {
        runGit(in: directory.path, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the 2-character status code into a GitFileStatus.
    private static func parseStatus(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "A" || workTree == "A" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    /// Mark parent directories with the most severe status of their children.
    private static func markParentDirectories(
        path: String,
        status: GitFileStatus,
        in map: inout [String: GitFileStatus]
    ) {
        var components = path.split(separator: "/")
        components.removeLast() // Remove filename
        var dirPath = ""
        for component in components {
            dirPath += "/" + component
            // Don't override a more severe status
            if map[dirPath] == nil {
                map[dirPath] = status
            }
        }
    }

    /// Run a git command and return stdout.
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
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

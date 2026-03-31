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
/// Keys match `FileExplorerNode.id` (relative paths starting with `/`).
enum GitStatusProvider {

    /// Fetch git status for files visible from the given directory.
    /// Returns [nodeId: GitFileStatus] where nodeId matches FileExplorerNode.id.
    static func fetchStatus(in directory: URL) -> [String: GitFileStatus] {
        let dirPath = directory.path

        // If the explorer root is itself a git repo, use it directly
        if let repoRoot = gitRepoRoot(for: dirPath) {
            debugLog("fetchStatus: direct repo repoRoot=\(repoRoot) explorerRoot=\(dirPath)")
            return fetchStatusFromRepo(repoRoot: repoRoot, explorerRoot: dirPath)
        }

        // Otherwise, scan immediate subdirectories for git repos
        debugLog("fetchStatus: \(dirPath) is not a repo, scanning subdirs")
        var combined: [String: GitFileStatus] = [:]
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return [:]
        }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if let repoRoot = gitRepoRoot(for: child.path) {
                let subResult = fetchStatusFromRepo(repoRoot: repoRoot, explorerRoot: dirPath)
                combined.merge(subResult) { _, new in new }
            }
        }
        debugLog("fetchStatus: scanned subdirs, total keys=\(combined.count)")
        return combined
    }

    private static func fetchStatusFromRepo(repoRoot: String, explorerRoot: String) -> [String: GitFileStatus] {
        guard let output = runGit(in: repoRoot, arguments: ["status", "--porcelain"]) else {
            debugLog("fetchStatusFromRepo: git status failed in \(repoRoot)")
            return [:]
        }

        var statusMap: [String: GitFileStatus] = [:]
        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")

            // Handle renames: "R  old -> new"
            if path.contains(" -> ") {
                path = String(path.split(separator: " -> ").last ?? Substring(path))
            }

            guard let status = parseStatus(index: indexStatus, workTree: workTreeStatus) else { continue }

            // Convert git path (relative to repo root) to absolute, then to node.id
            let absolutePath = repoRoot + "/" + path
            let nodeId = absoluteToNodeId(absolutePath: absolutePath, explorerRoot: explorerRoot)
            guard let nodeId else { continue }

            debugLog("fetchStatus: git='\(path)' abs='\(absolutePath)' nodeId='\(nodeId)' status=\(status)")
            statusMap[nodeId] = status
            markParentDirectories(path: nodeId, status: status, in: &statusMap)
        }
        debugLog("fetchStatus: total keys=\(statusMap.count) sample=\(Array(statusMap.keys.prefix(3)))")
        return statusMap
    }

    /// Convert an absolute file path to a node.id (relative to explorer root, starting with /).
    /// Returns nil if the file is outside the explorer root.
    private static func absoluteToNodeId(absolutePath: String, explorerRoot: String) -> String? {
        let cleanAbsolute = absolutePath.hasSuffix("/") ? String(absolutePath.dropLast()) : absolutePath
        let cleanRoot = explorerRoot.hasSuffix("/") ? String(explorerRoot.dropLast()) : explorerRoot

        guard cleanAbsolute.hasPrefix(cleanRoot + "/") else { return nil }
        return String(cleanAbsolute.dropFirst(cleanRoot.count))  // Already starts with /
    }

    private static func gitRepoRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseStatus(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "A" || workTree == "A" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    private static func markParentDirectories(
        path: String,
        status: GitFileStatus,
        in map: inout [String: GitFileStatus]
    ) {
        // Parent directories always show as "modified" — a directory isn't
        // "deleted" or "added" just because it contains such a file.
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var components = path.split(separator: "/")
        components.removeLast()
        var dirPath = ""
        for component in components {
            dirPath += "/" + component
            if map[dirPath] == nil {
                map[dirPath] = dirStatus
            }
        }
    }

    private static func debugLog(_ msg: String) {
        #if DEBUG
        let line = "\(Date()) [GitStatus] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/cmux-explorer-debug.log") {
                if let handle = FileHandle(forWritingAtPath: "/tmp/cmux-explorer-debug.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: "/tmp/cmux-explorer-debug.log", contents: data)
            }
        }
        #endif
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

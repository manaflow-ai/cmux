import Foundation

extension CmuxExtensionWorktreePrototype {
    /// Returns a bounded list of paths that worktree removal may delete when
    /// git's clean check does not protect the content, such as ignored files.
    static func forceRemovalPreview(
        worktreePath: String,
        itemLimit: Int = 20,
        traversalLimit: Int = 2_000
    ) async -> (paths: [String], truncated: Bool, scanFailed: Bool) {
        await Task.detached(priority: .userInitiated) { () -> (paths: [String], truncated: Bool, scanFailed: Bool) in
            let boundedItemLimit = max(1, itemLimit)
            let boundedTraversalLimit = max(boundedItemLimit, traversalLimit)
            let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true).standardizedFileURL.path
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: worktree, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return ([], false, true)
            }

            let statusPreview = forceRemovalGitStatusPreview(
                worktree: worktree,
                itemLimit: boundedItemLimit,
                maxBytes: 64 * 1_024
            )
            var paths = statusPreview.paths
            var seen = Set(paths)
            var truncated = statusPreview.truncated
            var scanFailed = statusPreview.scanFailed

            if paths.count < boundedItemLimit {
                let nestedPreview = forceRemovalNestedRepositoryPreview(
                    worktree: worktree,
                    itemLimit: boundedItemLimit,
                    traversalLimit: boundedTraversalLimit,
                    seen: seen
                )
                for path in nestedPreview.paths where !seen.contains(path) && paths.count < boundedItemLimit {
                    seen.insert(path)
                    paths.append(path)
                }
                truncated = truncated || nestedPreview.truncated
                scanFailed = scanFailed || nestedPreview.scanFailed
            } else {
                truncated = true
            }

            return (paths, truncated, scanFailed)
        }.value
    }

    private static func forceRemovalGitStatusPreview(
        worktree: String,
        itemLimit: Int,
        maxBytes: Int
    ) -> (paths: [String], truncated: Bool, scanFailed: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git", "-C", worktree,
            "status", "--porcelain=v1", "-z", "--ignored", "-uall",
        ]
        guard let stderr = FileHandle(forWritingAtPath: "/dev/null") else {
            return ([], false, true)
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            try? stderr.close()
            try? stdout.fileHandleForReading.close()
            return ([], false, true)
        }

        let byteLimit = max(1_024, maxBytes)
        var output = Data()
        var overByteLimit = false
        while true {
            let remaining = byteLimit + 1 - output.count
            let chunk = stdout.fileHandleForReading.readData(ofLength: min(8 * 1_024, remaining))
            if chunk.isEmpty {
                break
            }
            output.append(chunk)
            if output.count > byteLimit {
                overByteLimit = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        try? stdout.fileHandleForReading.close()
        try? stderr.close()
        guard overByteLimit || process.terminationStatus == 0 else {
            return ([], false, true)
        }

        let boundedOutput = overByteLimit ? Data(output.prefix(byteLimit)) : output
        guard let text = String(data: boundedOutput, encoding: .utf8) else {
            return ([], overByteLimit, true)
        }

        let records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < records.count && paths.count < itemLimit {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }

            let status = String(record.prefix(2))
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let path = String(record[pathStart...])
            if !path.isEmpty && path != ".git" {
                paths.append(path)
            }

            if status.contains("R") || status.contains("C") {
                index += 1
            }
        }

        return (paths, overByteLimit || index < records.count, false)
    }

    private static func forceRemovalNestedRepositoryPreview(
        worktree: String,
        itemLimit: Int,
        traversalLimit: Int,
        seen: Set<String>
    ) -> (paths: [String], truncated: Bool, scanFailed: Bool) {
        let worktreeURL = URL(fileURLWithPath: worktree, isDirectory: true).standardizedFileURL
        var scanFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: worktreeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                scanFailed = true
                return true
            }
        ) else {
            return ([], false, true)
        }

        var paths: [String] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > traversalLimit {
                return (paths, true, scanFailed)
            }

            guard let relativePath = forceRemovalRelativePath(for: url, rootPath: worktree) else {
                continue
            }
            guard url.lastPathComponent == ".git" else { continue }
            if forceRemovalPathIsDirectory(url) {
                enumerator.skipDescendants()
            }
            guard relativePath != ".git", !seen.contains(relativePath) else {
                continue
            }

            paths.append(relativePath)
            if paths.count >= itemLimit {
                return (paths, true, scanFailed)
            }
        }

        return (paths, false, scanFailed)
    }

    private static func forceRemovalRelativePath(for url: URL, rootPath: String) -> String? {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        let relativePath = String(path.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func forceRemovalPathIsDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

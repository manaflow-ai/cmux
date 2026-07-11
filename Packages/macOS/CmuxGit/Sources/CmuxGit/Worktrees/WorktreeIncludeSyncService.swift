public import CmuxFoundation
public import Foundation

/// Copies untracked source-checkout content selected by `.worktreeinclude` into a new worktree.
///
/// Git evaluates the include file as a gitignore-pattern list and intersects its
/// matches with the repository's standard ignores. The service preserves common
/// collapsible directory matches so large trees such as `node_modules/` can be
/// copied without enumerating every file.
///
/// Copy and matching failures are returned as diagnostics rather than thrown so
/// callers never discard an otherwise valid worktree.
public struct WorktreeIncludeSyncService: Sendable {
    private static let maximumPathspecBatchCount = 256
    private static let maximumPathspecBatchBytes = 64 * 1024

    private let commandRunner: any CommandRunning
    private let gitTimeout: TimeInterval
    // FileManager operations used here are documented thread-safe, and this
    // immutable injected instance has no delegate or mutable caller-owned state.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a worktree-include synchronization service.
    ///
    /// - Parameters:
    ///   - commandRunner: Runs Git pattern matching. Tests may inject a fake command runner.
    ///   - fileManager: Performs filesystem inspection and copies. Tests may inject an isolated manager.
    ///   - gitTimeout: Maximum duration of each Git matching command.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        fileManager: FileManager = .default,
        gitTimeout: TimeInterval = 30
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.gitTimeout = gitTimeout
    }

    /// Copies untracked paths selected by the source repository's `.worktreeinclude` file.
    ///
    /// Missing include files are a no-op. Git-tracked and non-ignored paths are
    /// excluded, and unsafe matches under `.git` or the source subtree containing
    /// an in-repository destination are skipped.
    ///
    /// - Parameters:
    ///   - sourceRoot: The root of the source Git checkout.
    ///   - destinationRoot: The root of the newly created Git worktree.
    /// - Returns: Non-fatal diagnostics produced while matching or copying paths.
    public nonisolated func sync(
        from sourceRoot: URL,
        to destinationRoot: URL
    ) async -> [String] {
        let source = sourceRoot.standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        let includeFile = source.appendingPathComponent(".worktreeinclude", isDirectory: false)

        var includeIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: includeFile.path, isDirectory: &includeIsDirectory) else {
            return []
        }
        guard !includeIsDirectory.boolValue else {
            return [".worktreeinclude is a directory, not a pattern file."]
        }
        guard source != destination else {
            return ["Skipped .worktreeinclude sync because source and destination are the same directory."]
        }

        var destinationIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
              destinationIsDirectory.boolValue else {
            return ["Skipped .worktreeinclude sync because the destination worktree does not exist."]
        }

        let includeArguments = [
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-from=\(includeFile.path)",
        ]
        let includeCollapsed = await gitPaths(
            source: source,
            arguments: includeArguments + ["--directory", "--no-empty-directory", "-z", "--"]
        )
        let includeDirectories = includeCollapsed.paths.filter { $0.hasSuffix("/") }
        let standardCollapsed = await standardIgnoredPaths(
            source: source,
            candidates: includeDirectories,
            collapseDirectories: true
        )
        let collapsedDirectoryExclusions = includeDirectories.map {
            "--exclude=!/\(gitignoreEscapedLiteralPath($0))"
        }
        let includeFiles = await gitPaths(
            source: source,
            arguments: includeArguments + collapsedDirectoryExclusions + ["-z", "--"]
        )
        let standardFiles = await standardIgnoredPaths(
            source: source,
            candidates: includeFiles.paths,
            collapseDirectories: false
        )

        var diagnostics = [
            includeCollapsed.diagnostic,
            includeFiles.diagnostic,
        ].compactMap { $0 } + standardCollapsed.diagnostics + standardFiles.diagnostics
        let candidates = Set(standardCollapsed.paths + standardFiles.paths).sorted()
        let protectedSourceSubtree = destinationContainer(
            destination: destination,
            inside: source
        )

        for relativePath in candidates {
            guard isSafe(
                relativePath: relativePath,
                source: source,
                destination: destination,
                protectedSourceSubtree: protectedSourceSubtree
            ) else {
                diagnostics.append("Skipped unsafe .worktreeinclude path: \(relativePath)")
                continue
            }

            let sourceItem = source.appendingPathComponent(relativePath).standardizedFileURL
            let destinationItem = destination.appendingPathComponent(relativePath).standardizedFileURL
            do {
                try fileManager.createDirectory(
                    at: destinationItem.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
            } catch {
                diagnostics.append("Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)")
            }
        }

        return diagnostics
    }

    private nonisolated func gitPaths(
        source: URL,
        arguments: [String]
    ) async -> (paths: [String], diagnostic: String?) {
        let result = await commandRunner.run(
            directory: source.path,
            executable: "git",
            arguments: arguments,
            timeout: gitTimeout
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            let detail: String
            if result.timedOut {
                detail = "git timed out after \(gitTimeout) seconds"
            } else {
                detail = result.executionError
                    ?? result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "git exited with status \(result.exitStatus.map(String.init) ?? "unknown")"
            }
            return ([], "Could not evaluate .worktreeinclude: \(detail)")
        }
        let paths = (result.stdout ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        return (paths, nil)
    }

    private nonisolated func standardIgnoredPaths(
        source: URL,
        candidates: [String],
        collapseDirectories: Bool
    ) async -> (paths: [String], diagnostics: [String]) {
        var paths: [String] = []
        var diagnostics: [String] = []
        for pathspecs in literalPathspecBatches(candidates) {
            var arguments = [
                "ls-files",
                "--others",
                "--ignored",
                "--exclude-standard",
            ]
            if collapseDirectories {
                arguments += ["--directory", "--no-empty-directory"]
            }
            arguments += ["-z", "--"] + pathspecs
            let result = await gitPaths(source: source, arguments: arguments)
            paths += result.paths
            if let diagnostic = result.diagnostic {
                diagnostics.append(diagnostic)
            }
        }
        return (paths, diagnostics)
    }

    private nonisolated func literalPathspecBatches(_ paths: [String]) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var batchBytes = 0

        for path in paths {
            let pathspec = ":(top,literal)\(path)"
            let pathspecBytes = pathspec.utf8.count + 1
            if !batch.isEmpty,
               batch.count >= Self.maximumPathspecBatchCount
                || batchBytes + pathspecBytes > Self.maximumPathspecBatchBytes {
                batches.append(batch)
                batch = []
                batchBytes = 0
            }
            batch.append(pathspec)
            batchBytes += pathspecBytes
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private nonisolated func gitignoreEscapedLiteralPath(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for character in path {
            if "\\*?[".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    private nonisolated func destinationContainer(
        destination: URL,
        inside source: URL
    ) -> URL? {
        let sourceComponents = source.pathComponents
        let destinationComponents = destination.pathComponents
        guard destinationComponents.count > sourceComponents.count,
              destinationComponents.starts(with: sourceComponents) else {
            return nil
        }
        let container = destination.deletingLastPathComponent().standardizedFileURL
        return container == source ? nil : container
    }

    private nonisolated func isSafe(
        relativePath: String,
        source: URL,
        destination: URL,
        protectedSourceSubtree: URL?
    ) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath != ".git",
              !relativePath.hasPrefix(".git/") else {
            return false
        }

        let relativeComponents = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativeComponents.isEmpty,
              !relativeComponents.contains("..") else {
            return false
        }

        let candidate = source.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.pathComponents.starts(with: source.pathComponents) else {
            return false
        }

        let candidateComponents = candidate.pathComponents
        let destinationComponents = destination.pathComponents
        let candidateContainsDestination = destinationComponents.starts(with: candidateComponents)
        let destinationContainsCandidate = candidateComponents.starts(with: destinationComponents)
        guard !candidateContainsDestination && !destinationContainsCandidate else {
            return false
        }

        if let protectedSourceSubtree {
            let protectedComponents = protectedSourceSubtree.pathComponents
            let candidateContainsProtectedSubtree = protectedComponents.starts(with: candidateComponents)
            let protectedSubtreeContainsCandidate = candidateComponents.starts(with: protectedComponents)
            if candidateContainsProtectedSubtree || protectedSubtreeContainsCandidate {
                return false
            }
        }
        return true
    }
}

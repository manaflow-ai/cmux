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

    private let commandRunner: any StandardInputCommandRunning
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
        commandRunner: any StandardInputCommandRunning = CommandRunner(),
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
        let standardCollapsed = await standardCollapsedDirectories(
            source: source,
            candidates: includeDirectories
        )
        let exclusionFile = writeCollapsedDirectoryExclusions(standardCollapsed.paths)
        defer {
            if let url = exclusionFile.url {
                try? fileManager.removeItem(at: url)
            }
        }
        let includeFiles: (paths: [String], diagnostic: String?)
        if let exclusionDiagnostic = exclusionFile.diagnostic {
            includeFiles = ([], exclusionDiagnostic)
        } else {
            let exclusionArguments = exclusionFile.url.map { ["--exclude-from=\($0.path)"] } ?? []
            includeFiles = await gitPaths(
                source: source,
                arguments: includeArguments + exclusionArguments + ["-z", "--"]
            )
        }
        let standardFiles = await standardIgnoredFiles(
            source: source,
            candidates: includeFiles.paths
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
            return ([], "Could not evaluate .worktreeinclude: \(gitFailureDetail(result))")
        }
        return (parseNulPaths(result.stdout), nil)
    }

    private nonisolated func parseNulPaths(_ output: String?) -> [String] {
        (output ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private nonisolated func gitFailureDetail(_ result: CommandResult) -> String {
        if result.timedOut {
            return "git timed out after \(gitTimeout) seconds"
        }
        return result.executionError
            ?? result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "git exited with status \(result.exitStatus.map(String.init) ?? "unknown")"
    }

    private nonisolated func standardCollapsedDirectories(
        source: URL,
        candidates: [String]
    ) async -> (paths: [String], diagnostics: [String]) {
        // Every candidate originated in `git ls-files --others`, so tracked
        // descendants cannot enter a directory copied from this result.
        var paths: [String] = []
        var diagnostics: [String] = []
        for pathspecs in literalPathspecBatches(candidates) {
            let collapsedResult = await gitPaths(
                source: source,
                arguments: [
                    "ls-files",
                    "--others",
                    "--ignored",
                    "--exclude-standard",
                    "--directory",
                    "--no-empty-directory",
                    "-z",
                    "--",
                ] + pathspecs
            )
            if let diagnostic = collapsedResult.diagnostic {
                diagnostics.append(diagnostic)
                continue
            }
            paths += collapsedResult.paths
        }
        return (paths, diagnostics)
    }

    private nonisolated func standardIgnoredFiles(
        source: URL,
        candidates: [String]
    ) async -> (paths: [String], diagnostics: [String]) {
        // `--no-index` asks check-ignore to evaluate each supplied path without
        // changing scope: every candidate already came from `ls-files --others`.
        // NUL-delimited stdin preserves arbitrary Git path bytes representable
        // by CommandRunner's UTF-8 output contract.
        var paths: [String] = []
        var diagnostics: [String] = []
        for batch in nulPathBatches(candidates) {
            var input = Data()
            input.reserveCapacity(batch.reduce(0) { $0 + $1.utf8.count + 1 })
            for path in batch {
                input.append(contentsOf: path.utf8)
                input.append(0)
            }
            let result = await commandRunner.run(
                directory: source.path,
                executable: "git",
                arguments: ["check-ignore", "--no-index", "--stdin", "-z"],
                standardInput: input,
                timeout: gitTimeout
            )
            guard result.executionError == nil,
                  !result.timedOut,
                  result.exitStatus == 0 || result.exitStatus == 1 else {
                diagnostics.append("Could not evaluate .worktreeinclude: \(gitFailureDetail(result))")
                continue
            }
            paths += parseNulPaths(result.stdout)
        }
        return (paths, diagnostics)
    }

    private nonisolated func writeCollapsedDirectoryExclusions(
        _ paths: [String]
    ) -> (url: URL?, diagnostic: String?) {
        guard !paths.isEmpty else { return (nil, nil) }
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-worktreeinclude-\(UUID().uuidString)",
            isDirectory: false
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            return (nil, "Could not create temporary .worktreeinclude exclusion file.")
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            for path in paths where path.hasSuffix("/") {
                let pattern = "!/\(gitignoreEscapedLiteralPath(path))\n"
                try handle.write(contentsOf: Data(pattern.utf8))
            }
            return (url, nil)
        } catch {
            try? fileManager.removeItem(at: url)
            return (nil, "Could not write temporary .worktreeinclude exclusion file: \(error.localizedDescription)")
        }
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

    private nonisolated func nulPathBatches(_ paths: [String]) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var batchBytes = 0

        for path in paths {
            let pathBytes = path.utf8.count + 1
            if !batch.isEmpty,
               batch.count >= Self.maximumPathspecBatchCount
                || batchBytes + pathBytes > Self.maximumPathspecBatchBytes {
                batches.append(batch)
                batch = []
                batchBytes = 0
            }
            batch.append(path)
            batchBytes += pathBytes
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

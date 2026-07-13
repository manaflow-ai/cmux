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
    private static let maximumMatchedPathCount = 10_000
    private static let maximumMatchedPathBytes = 16 * 1024 * 1024

    private let commandRunner: any OutputLimitedCommandRunning
    private let gitTimeout: TimeInterval
    private let copyService: WorktreeIncludeCopyService
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
        commandRunner: any OutputLimitedCommandRunning = CommandRunner(),
        fileManager: FileManager = .default,
        gitTimeout: TimeInterval = 30
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.gitTimeout = gitTimeout
        copyService = WorktreeIncludeCopyService(fileManager: fileManager)
    }

    init(
        commandRunner: any OutputLimitedCommandRunning = CommandRunner(),
        fileManager: FileManager = .default,
        gitTimeout: TimeInterval = 30,
        copyLimits: WorktreeIncludeCopyLimits,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { destination in
            if let capacity = try? destination.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage {
                return capacity
            }
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: destination.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        }
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.gitTimeout = gitTimeout
        copyService = WorktreeIncludeCopyService(
            fileManager: fileManager,
            limits: copyLimits,
            availableCapacity: availableCapacity
        )
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
    ///   - excludedRelativePaths: Destination subtrees reserved by the caller and excluded from copying.
    /// - Returns: Non-fatal diagnostics produced while matching or copying paths.
    public nonisolated func sync(
        from sourceRoot: URL,
        to destinationRoot: URL,
        excludingRelativePaths excludedRelativePaths: Set<String> = []
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
        guard !Task.isCancelled else {
            return ["Cancelled .worktreeinclude sync before Git matching began."]
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
        if includeCollapsed.shouldAbort {
            return [includeCollapsed.diagnostic].compactMap { $0 }
        }
        let includeDirectories = includeCollapsed.paths.filter { $0.hasSuffix("/") }
        let standardCollapsed = await standardCollapsedDirectories(
            source: source,
            candidates: includeDirectories
        )
        if standardCollapsed.shouldAbort {
            return [includeCollapsed.diagnostic].compactMap { $0 } + standardCollapsed.diagnostics
        }
        let hasNewlineCollapsedPath = standardCollapsed.paths.contains {
            $0.contains("\n") || $0.contains("\r")
        }
        if hasNewlineCollapsedPath {
            return [includeCollapsed.diagnostic].compactMap { $0 }
                + standardCollapsed.diagnostics
                + ["Skipped .worktreeinclude sync because a matched directory name contains a newline."]
        }
        let exclusionFile = writeCollapsedDirectoryExclusions(standardCollapsed.paths)
        defer {
            if let url = exclusionFile.url {
                try? fileManager.removeItem(at: url)
            }
        }
        let includeFiles: (paths: [String], diagnostic: String?, shouldAbort: Bool)
        if let exclusionDiagnostic = exclusionFile.diagnostic {
            includeFiles = ([], exclusionDiagnostic, false)
        } else {
            let exclusionArguments = exclusionFile.url.map { ["--exclude-from=\($0.path)"] } ?? []
            includeFiles = await gitPaths(
                source: source,
                arguments: includeArguments + exclusionArguments + ["-z", "--"]
            )
        }
        if includeFiles.shouldAbort {
            return [includeCollapsed.diagnostic, includeFiles.diagnostic].compactMap { $0 }
                + standardCollapsed.diagnostics
        }
        let standardFiles = await standardIgnoredFiles(
            source: source,
            candidates: includeFiles.paths
        )
        if standardFiles.shouldAbort {
            return [includeCollapsed.diagnostic, includeFiles.diagnostic].compactMap { $0 }
                + standardCollapsed.diagnostics
                + standardFiles.diagnostics
        }

        var diagnostics = [
            includeCollapsed.diagnostic,
            includeFiles.diagnostic,
        ].compactMap { $0 } + standardCollapsed.diagnostics + standardFiles.diagnostics
        let candidates = Set(standardCollapsed.paths + standardFiles.paths).sorted()
        guard candidates.count <= Self.maximumMatchedPathCount,
              matchedPathBytes(candidates) <= Self.maximumMatchedPathBytes else {
            diagnostics.append(matchLimitDiagnostic)
            return diagnostics
        }
        let protectedSourceSubtree = destinationContainer(destination: destination, inside: source)

        var safeCandidates: [String] = []
        for relativePath in candidates {
            let normalizedPath = relativePath.hasSuffix("/")
                ? String(relativePath.dropLast())
                : relativePath
            if excludedRelativePaths.contains(where: {
                normalizedPath == $0
                    || normalizedPath.hasPrefix($0 + "/")
                    || $0.hasPrefix(normalizedPath + "/")
            }) {
                diagnostics.append("Skipped reserved .worktreeinclude path: \(relativePath)")
                continue
            }
            guard isSafe(
                relativePath: relativePath,
                source: source,
                destination: destination,
                protectedSourceSubtree: protectedSourceSubtree
            ) else {
                diagnostics.append("Skipped unsafe .worktreeinclude path: \(relativePath)")
                continue
            }
            safeCandidates.append(relativePath)
        }
        return diagnostics + copyService.copy(relativePaths: safeCandidates, from: source, to: destination)
    }

    private nonisolated func gitPaths(
        source: URL,
        arguments: [String]
    ) async -> (paths: [String], diagnostic: String?, shouldAbort: Bool) {
        guard !Task.isCancelled else {
            return ([], "Cancelled .worktreeinclude sync during Git matching.", true)
        }
        let result = await commandRunner.run(
            directory: source.path,
            executable: "git",
            arguments: arguments,
            maximumOutputBytes: Self.maximumMatchedPathBytes,
            timeout: gitTimeout
        )
        guard !Task.isCancelled else {
            return ([], "Cancelled .worktreeinclude sync during Git matching.", true)
        }
        if result.outputLimitExceeded {
            return ([], matchLimitDiagnostic, true)
        }
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            return ([], "Could not evaluate .worktreeinclude: \(gitFailureDetail(result))", true)
        }
        guard let stdout = result.stdout else {
            return ([], "Could not evaluate .worktreeinclude: git output was not valid UTF-8.", true)
        }
        guard let paths = parseNulPaths(stdout) else {
            return ([], matchLimitDiagnostic, true)
        }
        return (paths, nil, false)
    }

    private nonisolated func parseNulPaths(_ output: String) -> [String]? {
        let records = output.split(
            separator: "\0",
            maxSplits: Self.maximumMatchedPathCount,
            omittingEmptySubsequences: true
        )
        guard records.count <= Self.maximumMatchedPathCount else { return nil }
        return records.map(String.init)
    }

    private nonisolated var matchLimitDiagnostic: String {
        "Could not evaluate .worktreeinclude: too many paths or output bytes (limit: \(Self.maximumMatchedPathCount) paths and \(Self.maximumMatchedPathBytes) bytes)."
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
    ) async -> (paths: [String], diagnostics: [String], shouldAbort: Bool) {
        // Every candidate originated in `git ls-files --others`, so tracked
        // descendants cannot enter a directory copied from this result.
        var paths: [String] = []
        var diagnostics: [String] = []
        var retainedPathBytes = 0
        for pathspecs in literalPathspecBatches(candidates) {
            guard !Task.isCancelled else {
                diagnostics.append("Cancelled .worktreeinclude sync during Git matching.")
                return ([], diagnostics, true)
            }
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
                return ([], diagnostics, collapsedResult.shouldAbort)
            }
            let newPathBytes = matchedPathBytes(collapsedResult.paths)
            guard paths.count + collapsedResult.paths.count <= Self.maximumMatchedPathCount,
                  retainedPathBytes + newPathBytes <= Self.maximumMatchedPathBytes else {
                diagnostics.append(matchLimitDiagnostic)
                return ([], diagnostics, true)
            }
            paths += collapsedResult.paths
            retainedPathBytes += newPathBytes
        }
        return (paths, diagnostics, false)
    }

    private nonisolated func standardIgnoredFiles(
        source: URL,
        candidates: [String]
    ) async -> (paths: [String], diagnostics: [String], shouldAbort: Bool) {
        // `--no-index` asks check-ignore to evaluate each supplied path without
        // changing scope: every candidate already came from `ls-files --others`.
        // NUL-delimited stdin preserves arbitrary Git path bytes representable
        // by CommandRunner's UTF-8 output contract.
        var paths: [String] = []
        var diagnostics: [String] = []
        var retainedPathBytes = 0
        for batch in nulPathBatches(candidates) {
            guard !Task.isCancelled else {
                diagnostics.append("Cancelled .worktreeinclude sync during Git matching.")
                return ([], diagnostics, true)
            }
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
                maximumOutputBytes: Self.maximumMatchedPathBytes,
                timeout: gitTimeout
            )
            if result.outputLimitExceeded {
                diagnostics.append(matchLimitDiagnostic)
                return ([], diagnostics, true)
            }
            guard result.executionError == nil,
                  !result.timedOut,
                  result.exitStatus == 0 || result.exitStatus == 1 else {
                diagnostics.append("Could not evaluate .worktreeinclude: \(gitFailureDetail(result))")
                return ([], diagnostics, true)
            }
            guard let stdout = result.stdout else {
                diagnostics.append("Could not evaluate .worktreeinclude: git output was not valid UTF-8.")
                return ([], diagnostics, true)
            }
            guard let matched = parseNulPaths(stdout) else {
                diagnostics.append(matchLimitDiagnostic)
                return ([], diagnostics, true)
            }
            let newPathBytes = matchedPathBytes(matched)
            guard paths.count + matched.count <= Self.maximumMatchedPathCount,
                  retainedPathBytes + newPathBytes <= Self.maximumMatchedPathBytes else {
                diagnostics.append(matchLimitDiagnostic)
                return ([], diagnostics, true)
            }
            paths += matched
            retainedPathBytes += newPathBytes
        }
        return (paths, diagnostics, false)
    }

    private nonisolated func matchedPathBytes(_ paths: [String]) -> Int {
        paths.reduce(0) { $0 + $1.utf8.count + 1 }
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

    private nonisolated func batches(
        _ paths: [String],
        transform: (String) -> String
    ) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var batchBytes = 0

        for path in paths {
            let item = transform(path)
            let itemBytes = item.utf8.count + 1
            if !batch.isEmpty,
               batch.count >= Self.maximumPathspecBatchCount
                || batchBytes + itemBytes > Self.maximumPathspecBatchBytes {
                batches.append(batch)
                batch = []
                batchBytes = 0
            }
            batch.append(item)
            batchBytes += itemBytes
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private nonisolated func literalPathspecBatches(_ paths: [String]) -> [[String]] {
        batches(paths) { ":(top,literal)\($0)" }
    }

    private nonisolated func nulPathBatches(_ paths: [String]) -> [[String]] {
        batches(paths) { $0 }
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

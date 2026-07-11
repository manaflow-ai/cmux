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
    private let commandRunner: any CommandRunning
    // FileManager operations used here are documented thread-safe, and this
    // immutable injected instance has no delegate or mutable caller-owned state.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a worktree-include synchronization service.
    ///
    /// - Parameters:
    ///   - commandRunner: Runs Git pattern matching. Tests may inject a fake command runner.
    ///   - fileManager: Performs filesystem inspection and copies. Tests may inject an isolated manager.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
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
        let standardIgnoreArguments = [
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
        ]
        async let includeCollapsedResult = gitPaths(
            source: source,
            arguments: includeArguments + ["--directory", "--no-empty-directory", "-z", "--"]
        )
        async let standardCollapsedResult = gitPaths(
            source: source,
            arguments: standardIgnoreArguments + ["--directory", "--no-empty-directory", "-z", "--"]
        )
        let (includeCollapsed, standardCollapsed) = await (
            includeCollapsedResult,
            standardCollapsedResult
        )

        let collapsedDirectories = collapsedDirectoryIntersections(
            includePaths: includeCollapsed.paths,
            standardIgnorePaths: standardCollapsed.paths
        )
        let filePathspecs = ["."] + collapsedDirectories.map {
            ":(top,exclude,literal)\($0)"
        }
        async let includeFileResult = gitPaths(
            source: source,
            arguments: includeArguments + ["-z", "--"] + filePathspecs
        )
        async let standardFileResult = gitPaths(
            source: source,
            arguments: standardIgnoreArguments + ["-z", "--"] + filePathspecs
        )
        let (includeFiles, standardFiles) = await (includeFileResult, standardFileResult)

        var diagnostics = [
            includeCollapsed.diagnostic,
            standardCollapsed.diagnostic,
            includeFiles.diagnostic,
            standardFiles.diagnostic,
        ].compactMap { $0 }
        let matchingFiles = Set(includeFiles.paths).intersection(standardFiles.paths)
        let candidates = Set(collapsedDirectories + Array(matchingFiles)).sorted()
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
            timeout: nil
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0 else {
            let detail = result.executionError
                ?? result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "git exited with status \(result.exitStatus.map(String.init) ?? "unknown")"
            return ([], "Could not evaluate .worktreeinclude: \(detail)")
        }
        let paths = (result.stdout ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        return (paths, nil)
    }

    private nonisolated func collapsedDirectoryIntersections(
        includePaths: [String],
        standardIgnorePaths: [String]
    ) -> [String] {
        let includeDirectories = includePaths.filter { $0.hasSuffix("/") }
        let standardDirectories = standardIgnorePaths.filter { $0.hasSuffix("/") }.sorted()
        let standardDirectorySet = Set(standardDirectories)
        var intersections = Set<String>()

        for includeDirectory in includeDirectories {
            var ancestor = ""
            var hasIgnoredAncestor = false
            for component in includeDirectory.split(separator: "/", omittingEmptySubsequences: true) {
                ancestor.append(contentsOf: component)
                ancestor.append("/")
                if standardDirectorySet.contains(ancestor) {
                    intersections.insert(includeDirectory)
                    hasIgnoredAncestor = true
                    break
                }
            }
            guard !hasIgnoredAncestor else { continue }

            var index = lowerBound(of: includeDirectory, in: standardDirectories)
            while index < standardDirectories.count,
                  standardDirectories[index].hasPrefix(includeDirectory) {
                intersections.insert(standardDirectories[index])
                index += 1
            }
        }
        return intersections.sorted()
    }

    private nonisolated func lowerBound(of value: String, in values: [String]) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
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

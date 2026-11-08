import Dispatch
import Foundation

extension GitMetadataService {
    private static let maximumRepositorySearchDepth = 256
    private static let maximumRepositoryPointerByteCount = 16 * 1_024

    /// Walks upward from `directory` to the nearest enclosing git repository.
    ///
    /// Handles a `.git` directory, a `.git` *file* (`gitdir:` pointer used by
    /// linked worktrees and submodules), and the shared `commondir`.
    ///
    /// - Parameter directory: An absolute path to start from. A path to a file
    ///   is treated as its containing directory.
    /// - Returns: The resolved repository, or `nil` if the filesystem root is
    ///   reached without finding one.
    nonisolated static func resolveGitRepository(
        containing directory: String,
        deadline: DispatchTime? = nil
    ) -> ResolvedGitRepository? {
        let startURL = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        var currentURL = startURL
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        for _ in 0..<Self.maximumRepositorySearchDepth {
            guard canContinueRepositoryResolution(deadline: deadline) else { return nil }
            let dotGitURL = currentURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) {
                let gitDirectory: String?
                if isDirectory.boolValue {
                    gitDirectory = dotGitURL.standardizedFileURL.path
                } else {
                    gitDirectory = gitDirectoryFromDotGitFile(
                        dotGitURL,
                        relativeTo: currentURL,
                        deadline: deadline
                    )
                }

                if let gitDirectory {
                    let commonDirectory = gitCommonDirectory(
                        gitDirectory: gitDirectory,
                        deadline: deadline
                    )
                    return ResolvedGitRepository(
                        workTreeRoot: currentURL.standardizedFileURL.path,
                        gitDirectory: gitDirectory,
                        commonDirectory: commonDirectory
                    )
                }
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if shouldStopGitRepositorySearch(currentURL: currentURL, parentURL: parentURL) {
                return nil
            }
            currentURL = parentURL
        }
        return nil
    }

    /// Resolves one nested repository without running filesystem probes on the
    /// Swift cooperative executor. The shared deadline and cancellation signal
    /// also bound reads of linked-worktree pointer files.
    nonisolated func resolveGitRepositoryBlocking(
        containing directory: String,
        deadline: DispatchTime
    ) async -> ResolvedGitRepository? {
        let cancellationSignal = WorkspaceChangesCancellationSignal(deadline: deadline)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let repository: ResolvedGitRepository? = cancellationSignal.withCurrentBinding {
                        guard deadline > DispatchTime.now() else { return nil }
                        return Self.resolveGitRepository(containing: directory, deadline: deadline)
                    }
                    continuation.resume(returning: repository)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }

    /// Whether the upward repository search should stop at `currentURL`.
    ///
    /// Stops at the filesystem root, or when the parent no longer differs from
    /// the current directory (so the walk cannot loop forever).
    nonisolated static func shouldStopGitRepositorySearch(currentURL: URL, parentURL: URL) -> Bool {
        if parentURL.path == currentURL.path {
            return true
        }

        let standardizedCurrentPath = currentURL.standardizedFileURL.path
        if standardizedCurrentPath == "/" {
            return true
        }

        return parentURL.standardizedFileURL.path == standardizedCurrentPath
    }

    /// Resolves the git directory a `.git` *file* points at via its `gitdir:`
    /// line, relative to the work-tree root when the path is relative.
    nonisolated static func gitDirectoryFromDotGitFile(
        _ dotGitURL: URL,
        relativeTo workTreeRootURL: URL,
        deadline: DispatchTime? = nil
    ) -> String? {
        guard let contents = repositoryPointerContents(at: dotGitURL, deadline: deadline) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard trimmed.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let rawPath = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: String(rawPath)).standardizedFileURL.path
        }
        return workTreeRootURL
            .appendingPathComponent(String(rawPath))
            .standardizedFileURL
            .path
    }

    /// Resolves the shared common directory for `gitDirectory` by reading its
    /// `commondir` file, falling back to `gitDirectory` itself.
    nonisolated static func gitCommonDirectory(
        gitDirectory: String,
        deadline: DispatchTime? = nil
    ) -> String {
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectory)
        let commonDirURL = gitDirectoryURL.appendingPathComponent("commondir")
        guard let contents = repositoryPointerContents(at: commonDirURL, deadline: deadline) else {
            return gitDirectory
        }

        let rawPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return gitDirectory }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }
        return gitDirectoryURL
            .appendingPathComponent(rawPath)
            .standardizedFileURL
            .path
    }

    private nonisolated static func canContinueRepositoryResolution(
        deadline: DispatchTime?
    ) -> Bool {
        !WorkspaceChangesCancellationSignal.isCurrentCancelled
            && (deadline.map { $0 > DispatchTime.now() } ?? true)
    }

    private nonisolated static func repositoryPointerContents(
        at url: URL,
        deadline: DispatchTime?
    ) -> String? {
        guard case .contents(let contents, consumedByteCount: _) = GitConfigFileReader().read(
            at: url,
            maximumByteCount: Self.maximumRepositoryPointerByteCount,
            deadline: deadline
        ) else {
            return nil
        }
        return contents
    }
}

import Foundation

extension GitMetadataService {
    /// Computes the sorted, existing paths to watch for a directory's git
    /// metadata, including submodule gitlinks. Returns `nil` when `directory` is
    /// not inside a repository.
    nonisolated static func workspaceGitMetadataWatchedPaths(
        for directory: String
    ) -> [String]? {
        workspaceGitMetadataWatchedPaths(for: directory, options: .full)
    }

    nonisolated static func workspaceGitMetadataWatchedPaths(
        for directory: String,
        options: GitMetadataReadOptions
    ) -> [String]? {
        guard let repository = resolveGitRepository(containing: directory) else {
            return nil
        }

        let candidatePaths =
            (options.includeWorkTreeRootWatchPath ? [repository.workTreeRoot] : [])
            + gitRepositoryMetadataWatchPaths(
                repository: repository,
                includeIndexWatchPath: options.includeIndexWatchPath
            )
            + (options.includeGitlinkWatchPaths
                ? gitlinkMetadataWatchPaths(
                    repository: repository,
                    includeIndexWatchPath: options.includeIndexWatchPath
                )
                : [])
        var watchedPaths: [String] = []
        var seen: Set<String> = []
        for path in candidatePaths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory) else {
                continue
            }
            watchedPaths.append(normalized)
        }

        return watchedPaths.sorted()
    }

    /// The metadata paths (`HEAD`, `index`, `refs`, `packed-refs`, every reachable
    /// `config`) for a single resolved repository.
    nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository,
        includeIndexWatchPath: Bool = true
    ) -> [String] {
        var paths = [
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs").path,
        ]
        if includeIndexWatchPath {
            paths.append(URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index").path)
        }
        return paths + gitConfigURLs(repository: repository).map(\.path)
    }

    /// The metadata paths contributed by gitlink (submodule) entries in the
    /// index, recursing into nested submodules so a checkout change at any
    /// depth wakes the watcher. Cycle-safe via the visited work-tree set.
    nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        includeIndexWatchPath: Bool = true
    ) -> [String] {
        var visitedWorkTreeRoots: Set<String> = [repository.workTreeRoot]
        return gitlinkMetadataWatchPaths(
            repository: repository,
            includeIndexWatchPath: includeIndexWatchPath,
            visitedWorkTreeRoots: &visitedWorkTreeRoots
        )
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository,
        includeIndexWatchPath: Bool,
        visitedWorkTreeRoots: inout Set<String>
    ) -> [String] {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL, includeContentSignature: false) else {
            return []
        }

        let gitlinkMode: UInt32 = 0o160000
        var paths: [String] = []
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkURL = URL(fileURLWithPath: repository.workTreeRoot)
                .appendingPathComponent(entry.path)
                .standardizedFileURL
            guard visitedWorkTreeRoots.insert(gitlinkURL.path).inserted,
                  let submoduleRepository = resolveGitRepository(containing: gitlinkURL.path),
                  submoduleRepository.workTreeRoot == gitlinkURL.path else {
                continue
            }
            paths.append(
                contentsOf: gitRepositoryMetadataWatchPaths(
                    repository: submoduleRepository,
                    includeIndexWatchPath: includeIndexWatchPath
                )
            )
            paths.append(
                contentsOf: gitlinkMetadataWatchPaths(
                    repository: submoduleRepository,
                    includeIndexWatchPath: includeIndexWatchPath,
                    visitedWorkTreeRoots: &visitedWorkTreeRoots
                )
            )
        }
        return paths
    }
}

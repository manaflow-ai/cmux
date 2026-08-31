import Dispatch
import Foundation

/// Mutable state for one synchronous, bounded config traversal.
nonisolated struct GitConfigTraversalState: Sendable {
    private static let maximumDeferredPathCount = 256

    var budget: GitConfigTraversalBudget
    var seenConfigPaths: Set<String> = []
    var configURLs: [URL] = []
    var referenceStorageName: String?
    var worktreeConfigEnabled = false
    var objectFormatSHA256 = false
    var didEncounterUnsafeInclude = false
    var missingConfigPaths: [String] = []
    var missingConfigParentPaths: [String] = []
    /// Include paths encountered after the bounded path budget was exhausted.
    /// These are retained as exact sentinels so omitted files outside `.git`
    /// can still invalidate the watch plan without broad directory overlap.
    var deferredConfigPaths: [String] = []
    var deferredConfigParentPaths: [String] = []

    /// Finds a local repository-owned parent for a missing optional include.
    func existingRepositoryConfigParent(
        for url: URL,
        repository: ResolvedGitRepository,
        configReader: GitConfigFileReader,
        deadline: DispatchTime?
    ) -> String? {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var current = parent
        for _ in 0..<16 {
            let path = current.path
            guard roots.contains(where: { root in
                path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }) else {
                return nil
            }
            if configReader.isLocalDirectory(at: current, deadline: deadline) {
                return path
            }
            let next = current.deletingLastPathComponent()
            if next.path == current.path { break }
            current = next
        }
        return nil
    }

    /// Retains an include discovered after the traversal budget was spent.
    /// Keeping its exact path and a watcher-only parent avoids broad metadata
    /// overlap when the include lives outside `.git`.
    mutating func recordDeferredIncludePath(
        _ includeURL: URL,
        repository: ResolvedGitRepository
    ) {
        guard deferredConfigPaths.count < Self.maximumDeferredPathCount else {
            return
        }
        let path = includeURL.standardizedFileURL.path
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard roots.contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else {
            didEncounterUnsafeInclude = true
            return
        }
        deferredConfigPaths.append(path)
        let parent = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        if roots.contains(where: { root in
            parent == root || parent.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) {
            deferredConfigParentPaths.append(parent)
        }
    }
}

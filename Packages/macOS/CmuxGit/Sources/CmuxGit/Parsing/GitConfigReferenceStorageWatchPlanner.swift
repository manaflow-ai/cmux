import Dispatch
import Foundation

/// Derives bounded watcher paths for a configured Git reference store.
nonisolated struct GitConfigReferenceStorageWatchPlanner: Sendable {
    private let repository: ResolvedGitRepository
    private let branchContext: GitConfigBranchContext
    private let configReader: GitConfigFileReader
    private let deadline: DispatchTime?

    init(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        configReader: GitConfigFileReader,
        deadline: DispatchTime?
    ) {
        self.repository = repository
        self.branchContext = branchContext
        self.configReader = configReader
        self.deadline = deadline
    }

    /// Returns bounded paths that can invalidate one reference store.
    func watchPaths(storageName: String, path: String) -> [String] {
        guard storageName == "reftable" || storageName == "files" else { return [] }
        guard isSafeReferenceStoragePath(path, storageName: storageName) else { return [] }
        let root = URL(fileURLWithPath: path)
        if storageName == "reftable" {
            return watchPath(
                root.appendingPathComponent("tables.list"),
                allowParentSentinel: isRepositoryLocal(path)
            )
        }
        return filesWatchPaths(root: root)
    }

    private func filesWatchPaths(root: URL) -> [String] {
        var paths: [String] = []
        if let branch = branchContext.branchName(for: repository, deadline: deadline) {
            let refsRoot = root.appendingPathComponent("refs", isDirectory: true)
            let branchRef = refsRoot
                .appendingPathComponent("heads", isDirectory: true)
                .appendingPathComponent(branch, isDirectory: false)
                .standardizedFileURL
            let refsPath = refsRoot.standardizedFileURL.path
            if branchRef.path.hasPrefix(refsPath + "/") {
                paths.append(contentsOf: watchPath(branchRef, allowParentSentinel: true))
            }
        }
        paths.append(contentsOf: watchPath(
            root.appendingPathComponent("packed-refs"),
            allowParentSentinel: false
        ))
        return Array(Set(paths)).prefix(8).map { $0 }
    }

    private func isSafeReferenceStoragePath(_ path: String, storageName: String) -> Bool {
        guard path != "/" else { return false }
        if isRepositoryLocal(path) { return true }
        guard storageName == "reftable" || storageName == "files" else { return false }
        let root = URL(fileURLWithPath: path)
        guard configReader.isLocalDirectory(at: root, deadline: deadline) else { return false }
        if storageName == "reftable" {
            return configReader.isLocalRegularFile(
                at: root.appendingPathComponent("tables.list"),
                deadline: deadline
            )
        }
        return configReader.isLocalDirectory(
            at: root.appendingPathComponent("refs/heads", isDirectory: true),
            deadline: deadline
        ) || configReader.isLocalRegularFile(
            at: root.appendingPathComponent("packed-refs"),
            deadline: deadline
        )
    }

    private func isRepositoryLocal(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .contains { root in
                standardized == root || standardized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
    }

    private func watchPath(_ targetURL: URL, allowParentSentinel: Bool) -> [String] {
        let target = targetURL.standardizedFileURL
        if configReader.isLocalRegularFile(at: target, deadline: deadline) {
            return [target.path]
        }
        guard allowParentSentinel else { return [] }
        let parent = target.deletingLastPathComponent()
        guard configReader.isLocalDirectory(at: parent, deadline: deadline) else { return [] }
        return [parent.path]
    }
}

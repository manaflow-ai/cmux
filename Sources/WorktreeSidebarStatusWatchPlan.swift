import Foundation

/// Filesystem boundaries that can change one worktree row's Git status.
struct WorktreeSidebarStatusWatchPlan: Equatable, Sendable {
    static let empty = WorktreeSidebarStatusWatchPlan(recursivePaths: [], shallowPaths: [])

    let recursivePaths: [String]
    let shallowPaths: [String]
}

/// Partitions a worktree around Git-registered descendant worktrees.
///
/// Descendant worktrees may be created by cmux or directly in a shell. Their
/// subtrees are never watched on behalf of an ancestor row; shallow watchers on
/// the boundary directories still detect additions, removals, and renames.
struct WorktreeSidebarStatusWatchPlanner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func makePlan(
        worktreePath: String,
        gitDirectory: String,
        metadataPaths: [String],
        excludedWorktreePaths: [String]
    ) -> WorktreeSidebarStatusWatchPlan {
        let root = normalized(worktreePath)
        let gitRoot = normalized(gitDirectory)
        var exclusions = excludedWorktreePaths
            .map(normalized)
            .filter { isDescendant($0, of: root) }
        if isDescendant(gitRoot, of: root) {
            exclusions.append(gitRoot)
        }
        exclusions = Array(Set(exclusions)).sorted()

        var recursivePaths = metadataPaths.compactMap { path -> String? in
            let normalizedPath = normalized(path)
            let name = URL(fileURLWithPath: normalizedPath).lastPathComponent
            return name == "HEAD" || name == "index" ? normalizedPath : nil
        }
        var shallowPaths: [String] = []
        if exclusions.isEmpty {
            recursivePaths.append(root)
        } else {
            partition(
                directory: root,
                exclusions: exclusions,
                recursivePaths: &recursivePaths,
                shallowPaths: &shallowPaths
            )
        }
        return WorktreeSidebarStatusWatchPlan(
            recursivePaths: Array(Set(recursivePaths)).sorted(),
            shallowPaths: Array(Set(shallowPaths)).sorted()
        )
    }

    private func partition(
        directory: String,
        exclusions: [String],
        recursivePaths: inout [String],
        shallowPaths: inout [String]
    ) {
        shallowPaths.append(directory)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            let child = normalized(
                URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(name)
                    .path
            )
            let childExclusions = exclusions.filter { $0 == child || isDescendant($0, of: child) }
            if childExclusions.contains(child) { continue }
            if childExclusions.isEmpty {
                recursivePaths.append(child)
            } else {
                partition(
                    directory: child,
                    exclusions: childExclusions,
                    recursivePaths: &recursivePaths,
                    shallowPaths: &shallowPaths
                )
            }
        }
    }

    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isDescendant(_ candidate: String, of root: String) -> Bool {
        candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

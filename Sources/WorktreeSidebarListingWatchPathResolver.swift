import Foundation

/// Derives direct membership and exact metadata paths for worktree-list refreshes.
struct WorktreeSidebarListingWatchPathResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func makePlan(commonDirectory: String) -> WorktreeSidebarListingWatchPlan {
        let common = URL(fileURLWithPath: commonDirectory, isDirectory: true)
            .standardizedFileURL
        let worktrees = common.appendingPathComponent("worktrees", isDirectory: true)
        var metadataPaths = [
            common.appendingPathComponent("HEAD", isDirectory: false).path,
        ]

        let names = (try? fileManager.contentsOfDirectory(atPath: worktrees.path)) ?? []
        for name in names {
            let administration = worktrees.appendingPathComponent(name, isDirectory: true)
            metadataPaths.append(administration.appendingPathComponent("HEAD", isDirectory: false).path)
            metadataPaths.append(administration.appendingPathComponent("locked", isDirectory: false).path)
            metadataPaths.append(administration.appendingPathComponent("gitdir", isDirectory: false).path)
        }

        return WorktreeSidebarListingWatchPlan(
            membershipDirectory: worktrees.path,
            metadataPaths: Array(Set(metadataPaths)).sorted()
        )
    }
}

import Foundation

/// A path a plan named that seeding could not deliver.
public struct WorktreeSeedFailure: Sendable, Equatable {
    /// Path relative to the repository root.
    public var relativePath: String
    /// What went wrong, as the filesystem reported it. Not user-facing copy.
    public var reason: String

    /// Creates a failure.
    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// What applying a plan did.
public struct WorktreeSeedReport: Sendable, Equatable {
    /// Paths copied into the worktree.
    public var copied: [String]
    /// Paths linked to the original.
    public var linked: [String]
    /// Paths the worktree already had, left as git checked them out.
    public var skipped: [String]
    /// Paths that could not be delivered.
    public var failed: [WorktreeSeedFailure]

    /// Creates a report.
    public init(
        copied: [String] = [],
        linked: [String] = [],
        skipped: [String] = [],
        failed: [WorktreeSeedFailure] = []
    ) {
        self.copied = copied
        self.linked = linked
        self.skipped = skipped
        self.failed = failed
    }

    /// Whether every entry in the plan was delivered.
    public var isComplete: Bool { failed.isEmpty }
    /// How many paths the worktree gained.
    public var deliveredCount: Int { copied.count + linked.count }
}

/// Copies and links the paths a plan names into a new worktree.
///
/// One entry failing does not stop the others: a worktree with four of its five
/// ignored files is more useful than one with none, and the report names what is
/// missing. Nothing is ever overwritten, because the file git just checked out is
/// the one the worktree should keep.
public struct WorktreeSeedApplier: Sendable {
    /// Creates an applier.
    public init() {}

    /// Delivers `plan` from `source` into `destination`.
    ///
    /// A `.link` entry becomes an absolute symlink to the source path. Absolute is
    /// the right choice for what gets linked: `node_modules` and friends are
    /// wanted because the original is installed where it is, and the worktree may
    /// later move without the original moving with it.
    public func apply(_ plan: WorktreeSeedPlan, from source: URL, to destination: URL) -> WorktreeSeedReport {
        var report = WorktreeSeedReport()
        let fileManager = FileManager.default
        let destinationRoot = destination.standardizedFileURL.path

        for entry in plan.entries {
            let from = source.appendingPathComponent(entry.relativePath)
            let to = destination.appendingPathComponent(entry.relativePath)

            guard to.standardizedFileURL.path == destinationRoot + "/" + entry.relativePath else {
                report.failed.append(
                    WorktreeSeedFailure(
                        relativePath: entry.relativePath,
                        reason: "resolves outside the worktree"
                    )
                )
                continue
            }
            guard fileManager.fileExists(atPath: from.path) else {
                report.failed.append(
                    WorktreeSeedFailure(relativePath: entry.relativePath, reason: "no longer in the repository")
                )
                continue
            }
            if fileExistsWithoutFollowingLinks(to) {
                report.skipped.append(entry.relativePath)
                continue
            }

            let parent = to.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                report.failed.append(
                    WorktreeSeedFailure(relativePath: entry.relativePath, reason: String(describing: error))
                )
                continue
            }

            do {
                switch entry.action {
                case .copy:
                    try fileManager.copyItem(at: from, to: to)
                    report.copied.append(entry.relativePath)
                case .link:
                    try fileManager.createSymbolicLink(
                        atPath: to.path,
                        withDestinationPath: from.standardizedFileURL.path
                    )
                    report.linked.append(entry.relativePath)
                }
            } catch {
                report.failed.append(
                    WorktreeSeedFailure(relativePath: entry.relativePath, reason: String(describing: error))
                )
            }
        }
        return report
    }

    /// Whether the path is taken, counting a dangling symlink as taken.
    ///
    /// `fileExists` follows links, so a symlink whose target is missing reads as
    /// absent, and the write then fails on a path that is occupied after all.
    /// `attributesOfItem` does not follow links.
    private func fileExistsWithoutFollowingLinks(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

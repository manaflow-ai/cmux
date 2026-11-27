import Foundation

/// One path a new worktree should receive.
public struct WorktreeSeedEntry: Sendable, Equatable {
    /// Path relative to the repository root, `/`-separated, never empty.
    public var relativePath: String
    /// Copy or link.
    public var action: WorktreeSeedAction
    /// Whether the path is a directory, which decides whether a copy is recursive.
    public var isDirectory: Bool
    /// The `.worktreeinclude` line that decided this entry.
    public var line: Int

    /// Creates an entry.
    public init(relativePath: String, action: WorktreeSeedAction, isDirectory: Bool, line: Int) {
        self.relativePath = relativePath
        self.action = action
        self.isDirectory = isDirectory
        self.line = line
    }
}

/// A path a pattern selected and something else then ruled out.
public struct WorktreeSeedDecision: Sendable, Equatable {
    /// Path relative to the repository root.
    public var relativePath: String
    /// The line that last matched the path.
    public var line: Int

    /// Creates a decision.
    public init(relativePath: String, line: Int) {
        self.relativePath = relativePath
        self.line = line
    }
}

/// A selected path that an already selected ancestor covers.
public struct WorktreeSeedShadow: Sendable, Equatable {
    /// The redundant path.
    public var relativePath: String
    /// The ancestor that already carries it.
    public var coveredBy: String
    /// What the ancestor does, which is why the nested entry is dropped rather than kept.
    ///
    /// Under a copied ancestor the nested entry is merely redundant. Under a
    /// linked one, honoring it would write through the symlink and into the
    /// original repository, so it must not be honored.
    public var coveringAction: WorktreeSeedAction

    /// Creates a shadow.
    public init(relativePath: String, coveredBy: String, coveringAction: WorktreeSeedAction) {
        self.relativePath = relativePath
        self.coveredBy = coveredBy
        self.coveringAction = coveringAction
    }
}

/// What a `.worktreeinclude` asks for, resolved against a repository.
///
/// The plan is data. Nothing here touches the destination: a caller can print it,
/// diff it, or apply it, and the tests can read it without a filesystem.
public struct WorktreeSeedPlan: Sendable, Equatable {
    /// The paths to seed, ordered by path.
    public var entries: [WorktreeSeedEntry]
    /// Paths a `!` pattern removed.
    public var excluded: [WorktreeSeedDecision]
    /// Paths that are symlinks out of the repository, which seeding will not follow.
    public var refused: [WorktreeSeedDecision]
    /// Paths dropped because a selected ancestor already covers them.
    public var shadowed: [WorktreeSeedShadow]
    /// Paths the destination already has, left alone rather than overwritten.
    public var alreadyPresent: [WorktreeSeedDecision]
    /// Patterns that matched nothing, so their author can delete or fix them.
    public var unmatched: [WorktreeSeedPattern]
    /// Patterns whose walk ran out of directory budget before it finished.
    ///
    /// Kept apart from `unmatched`: a pattern that was cut short may well match
    /// something, and telling its author it matched nothing reads as advice to
    /// delete the line.
    public var truncated: [WorktreeSeedPattern]
    /// `!` patterns whose only matches sit inside a wholesale-selected directory.
    ///
    /// Those cannot be honored, and a silent no-op would read as an exclusion
    /// that worked. See `WorktreeSeedPlanner` on why a directory is selected whole.
    public var ineffectiveNegations: [WorktreeSeedShadow]
    /// Whether a `**` pattern hit the directory budget, which means the plan is incomplete.
    public var reachedWalkLimit: Bool

    /// Creates a plan.
    public init(
        entries: [WorktreeSeedEntry] = [],
        excluded: [WorktreeSeedDecision] = [],
        refused: [WorktreeSeedDecision] = [],
        shadowed: [WorktreeSeedShadow] = [],
        alreadyPresent: [WorktreeSeedDecision] = [],
        unmatched: [WorktreeSeedPattern] = [],
        truncated: [WorktreeSeedPattern] = [],
        ineffectiveNegations: [WorktreeSeedShadow] = [],
        reachedWalkLimit: Bool = false
    ) {
        self.entries = entries
        self.excluded = excluded
        self.refused = refused
        self.shadowed = shadowed
        self.alreadyPresent = alreadyPresent
        self.unmatched = unmatched
        self.truncated = truncated
        self.ineffectiveNegations = ineffectiveNegations
        self.reachedWalkLimit = reachedWalkLimit
    }

    /// Whether applying the plan would do nothing.
    public var isEmpty: Bool { entries.isEmpty }

    /// The paths to copy, in plan order.
    public var copies: [WorktreeSeedEntry] { entries.filter { $0.action == .copy } }
    /// The paths to link, in plan order.
    public var links: [WorktreeSeedEntry] { entries.filter { $0.action == .link } }
}

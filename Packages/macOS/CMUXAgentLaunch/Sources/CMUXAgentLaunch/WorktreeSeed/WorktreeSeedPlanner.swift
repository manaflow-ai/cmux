import Foundation

/// One child of a directory, as the repository reports it.
public struct WorktreeSeedListedEntry: Sendable, Equatable {
    /// The child's name, with no separators.
    public var name: String
    /// Whether it is a directory, following a symlink the way a copy would.
    public var isDirectory: Bool
    /// Whether it is a symlink whose target resolves outside the repository root.
    ///
    /// Seeding will not follow one: the point of a worktree is a tree of its own,
    /// and a link out of the repository silently shares state with whatever it
    /// points at.
    public var escapesRepository: Bool

    /// Creates an entry.
    public init(name: String, isDirectory: Bool, escapesRepository: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.escapesRepository = escapesRepository
    }
}

/// Resolves a `.worktreeinclude` against a repository into a plan.
///
/// The repository is reached only through `listing`, which returns the children of
/// a repository-relative directory (`""` for the root). That keeps the planner
/// testable without a filesystem, and it keeps the walk honest: a pattern is
/// expanded one directory level at a time, so `.env` lists the root and stops.
/// Only `**` descends, and `maximumVisitedDirectories` bounds it, because the
/// directories a seeding pattern is aimed at (`node_modules`, `.venv`) are the
/// ones that would make an unbounded walk take minutes.
///
/// A matched directory is selected whole. The planner does not plan the inside of
/// it, because the two actions differ there: a copy could filter its contents, a
/// link cannot filter anything. Selecting whole directories keeps one rule for
/// both, and `WorktreeSeedPlan.ineffectiveNegations` reports the patterns that
/// rule silently disarms.
public struct WorktreeSeedPlanner: Sendable {
    /// Returns the children of a repository-relative directory. `""` is the root.
    public typealias Listing = @Sendable (String) -> [WorktreeSeedListedEntry]

    /// How many directories a single expansion may list before it gives up.
    ///
    /// Counted per pattern, not per file, so one greedy line cannot starve the
    /// rest. A pattern that hits it is reported in `WorktreeSeedPlan.truncated`.
    public var maximumVisitedDirectories: Int

    private let listing: Listing

    /// Creates a planner over a repository.
    public init(maximumVisitedDirectories: Int = 20_000, listing: @escaping Listing) {
        self.maximumVisitedDirectories = maximumVisitedDirectories
        self.listing = listing
    }

    /// Resolves `file` against the repository.
    ///
    /// `alreadyPresent` holds repository-relative paths the destination worktree
    /// already has. They are reported rather than overwritten: the file git just
    /// checked out is the one the worktree should keep.
    public func plan(for file: WorktreeSeedFile, alreadyPresent: Set<String> = []) -> WorktreeSeedPlan {
        var plan = WorktreeSeedPlan()
        var matchesByLine: [Int: [String: WorktreeSeedListedEntry]] = [:]

        for pattern in file.patterns {
            // The budget is per pattern. Sharing one across the file made a
            // single `**` starve every line after it, and those lines then
            // looked like patterns that matched nothing, which is advice to
            // delete a line that was never tried.
            var visited = 0
            let expansion = expand(pattern, visited: &visited)
            matchesByLine[pattern.line] = expansion.matches
            if expansion.reachedLimit {
                plan.reachedWalkLimit = true
                plan.truncated.append(pattern)
                continue
            }
            if expansion.matches.isEmpty { plan.unmatched.append(pattern) }
        }

        var candidates: [String: WorktreeSeedListedEntry] = [:]
        for pattern in file.patterns where !pattern.isNegated {
            for (path, entry) in matchesByLine[pattern.line] ?? [:] {
                candidates[path] = entry
            }
        }

        var selected: [String: WorktreeSeedEntry] = [:]
        for path in candidates.keys.sorted() {
            guard let entry = candidates[path] else { continue }
            guard let deciding = lastPattern(in: file.patterns, matching: path, isDirectory: entry.isDirectory) else { continue }
            if deciding.isNegated {
                plan.excluded.append(WorktreeSeedDecision(relativePath: path, line: deciding.line))
                continue
            }
            if entry.escapesRepository {
                plan.refused.append(WorktreeSeedDecision(relativePath: path, line: deciding.line))
                continue
            }
            if alreadyPresent.contains(path) {
                plan.alreadyPresent.append(WorktreeSeedDecision(relativePath: path, line: deciding.line))
                continue
            }
            selected[path] = WorktreeSeedEntry(
                relativePath: path,
                action: deciding.action,
                isDirectory: entry.isDirectory,
                line: deciding.line
            )
        }

        var retained: [String: WorktreeSeedEntry] = [:]
        for path in selected.keys.sorted() {
            guard let entry = selected[path] else { continue }
            if let ancestor = nearestSelectedAncestor(of: path, in: retained) {
                plan.shadowed.append(
                    WorktreeSeedShadow(
                        relativePath: path,
                        coveredBy: ancestor.relativePath,
                        coveringAction: ancestor.action
                    )
                )
                continue
            }
            retained[path] = entry
            plan.entries.append(entry)
        }

        for pattern in file.patterns where pattern.isNegated {
            for path in (matchesByLine[pattern.line] ?? [:]).keys.sorted() {
                guard selected[path] == nil else { continue }
                guard let ancestor = nearestSelectedAncestor(of: path, in: retained) else { continue }
                plan.ineffectiveNegations.append(
                    WorktreeSeedShadow(
                        relativePath: path,
                        coveredBy: ancestor.relativePath,
                        coveringAction: ancestor.action
                    )
                )
            }
        }

        plan.entries.sort { $0.relativePath < $1.relativePath }
        plan.excluded.sort { $0.relativePath < $1.relativePath }
        plan.refused.sort { $0.relativePath < $1.relativePath }
        plan.alreadyPresent.sort { $0.relativePath < $1.relativePath }
        plan.shadowed.sort { $0.relativePath < $1.relativePath }
        plan.ineffectiveNegations.sort { $0.relativePath < $1.relativePath }
        return plan
    }

    /// The selected directory closest to `path` that contains it, if any.
    private func nearestSelectedAncestor(
        of path: String,
        in selected: [String: WorktreeSeedEntry]
    ) -> WorktreeSeedEntry? {
        var segments = path.split(separator: "/").map(String.init)
        segments.removeLast()
        while !segments.isEmpty {
            let candidate = segments.joined(separator: "/")
            if let entry = selected[candidate], entry.isDirectory { return entry }
            segments.removeLast()
        }
        return nil
    }

    /// The last pattern in file order that matches the path, which is the one that decides it.
    private func lastPattern(
        in patterns: [WorktreeSeedPattern],
        matching path: String,
        isDirectory: Bool
    ) -> WorktreeSeedPattern? {
        patterns.last { WorktreeSeedPlanner.pattern($0, matches: path, isDirectory: isDirectory) }
    }

    private struct Expansion {
        var matches: [String: WorktreeSeedListedEntry] = [:]
        var reachedLimit = false
    }

    /// Walks the repository for the paths a single pattern selects.
    private func expand(_ pattern: WorktreeSeedPattern, visited: inout Int) -> Expansion {
        var expansion = Expansion()
        let segments = pattern.segments
        guard !segments.isEmpty else { return expansion }

        var frontier: [(index: Int, directory: String)] = [(0, "")]
        var seen: Set<String> = []

        while let state = frontier.popLast() {
            let key = "\(state.index)\u{0}\(state.directory)"
            guard seen.insert(key).inserted else { continue }
            if visited >= maximumVisitedDirectories {
                expansion.reachedLimit = true
                return expansion
            }
            visited += 1
            let children = listing(state.directory)
            let segment = segments[state.index]
            let isLast = state.index == segments.count - 1

            if segment == "**" {
                if !isLast { frontier.append((state.index + 1, state.directory)) }
                for child in children {
                    let path = state.directory.isEmpty ? child.name : state.directory + "/" + child.name
                    if isLast, !pattern.directoryOnly || child.isDirectory {
                        expansion.matches[path] = child
                    }
                    if child.isDirectory { frontier.append((state.index, path)) }
                }
                continue
            }

            for child in children where WorktreeSeedPlanner.glob(segment, matches: child.name) {
                let path = state.directory.isEmpty ? child.name : state.directory + "/" + child.name
                if isLast {
                    if pattern.directoryOnly, !child.isDirectory { continue }
                    expansion.matches[path] = child
                } else if child.isDirectory {
                    frontier.append((state.index + 1, path))
                }
            }
        }
        return expansion
    }
}

extension WorktreeSeedPlanner {
    /// Whether a pattern matches a repository-relative path.
    ///
    /// Exposed because negation asks the question about paths the expansion did
    /// not produce.
    public static func pattern(
        _ pattern: WorktreeSeedPattern,
        matches path: String,
        isDirectory: Bool
    ) -> Bool {
        if pattern.directoryOnly, !isDirectory { return false }
        let patternSegments = pattern.segments
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var failed = Set<Int>()

        func walk(_ patternIndex: Int, _ pathIndex: Int) -> Bool {
            let key = patternIndex * (pathSegments.count + 1) + pathIndex
            guard !failed.contains(key) else { return false }
            if patternIndex == patternSegments.count {
                return pathIndex == pathSegments.count
            }
            if patternSegments[patternIndex] == "**" {
                // A trailing `**` means everything below, so it must consume
                // at least one segment. Otherwise it either consumes nothing
                // or one segment; memoization bounds the state space to the
                // pattern/path grid.
                if patternIndex == patternSegments.count - 1 {
                    return pathIndex < pathSegments.count
                }
                if walk(patternIndex + 1, pathIndex) { return true }
                if pathIndex < pathSegments.count, walk(patternIndex, pathIndex + 1) {
                    return true
                }
            } else if pathIndex < pathSegments.count,
                      glob(patternSegments[patternIndex], matches: pathSegments[pathIndex]),
                      walk(patternIndex + 1, pathIndex + 1)
            {
                return true
            }
            failed.insert(key)
            return false
        }

        return walk(0, 0)
    }

    /// Matches one path segment.
    ///
    /// `*` matches any run of characters within the segment, `?` matches one, and
    /// `\` escapes the next character. There are no character classes: a seeding
    /// list names files, and `[` is a legal character in a filename.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        let patternCharacters = Array(pattern)
        let nameCharacters = Array(name)
        var memo = Set<Int>()

        func walk(_ patternIndex: Int, _ nameIndex: Int) -> Bool {
            let key = patternIndex * (nameCharacters.count + 1) + nameIndex
            guard !memo.contains(key) else { return false }
            if patternIndex == patternCharacters.count { return nameIndex == nameCharacters.count }
            switch patternCharacters[patternIndex] {
            case "*":
                // A run of `*` (including the in-segment `**`) behaves as one.
                var next = patternIndex
                while next < patternCharacters.count, patternCharacters[next] == "*" { next += 1 }
                for skip in nameIndex...nameCharacters.count {
                    if walk(next, skip) { return true }
                }
            case "?":
                if nameIndex < nameCharacters.count, walk(patternIndex + 1, nameIndex + 1) { return true }
            case "\\" where patternIndex + 1 < patternCharacters.count:
                if nameIndex < nameCharacters.count,
                   patternCharacters[patternIndex + 1] == nameCharacters[nameIndex],
                   walk(patternIndex + 2, nameIndex + 1) { return true }
            case let character:
                if nameIndex < nameCharacters.count,
                   character == nameCharacters[nameIndex],
                   walk(patternIndex + 1, nameIndex + 1) { return true }
            }
            memo.insert(key)
            return false
        }

        return walk(0, 0)
    }
}

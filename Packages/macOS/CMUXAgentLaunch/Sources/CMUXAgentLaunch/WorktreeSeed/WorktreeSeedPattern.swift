import Foundation

/// What a new worktree should do with a path the repository ignores.
public enum WorktreeSeedAction: String, Sendable, Equatable, CaseIterable {
    /// Copy the file or directory into the new worktree.
    case copy
    /// Point a symlink at the original instead of copying it.
    ///
    /// This is what `node_modules`, `.venv` and build caches want: copying them
    /// costs minutes and gigabytes, and the two trees are interchangeable.
    case link
}

/// One line of a `.worktreeinclude` file.
///
/// The file names the paths a fresh `git worktree` needs but cannot get from
/// git, because they are ignored: `.env`, a local settings file, an installed
/// dependency directory. Without them the first command an agent runs in its
/// new worktree fails on missing configuration.
///
/// The syntax is deliberately close to `.gitignore` so it is learnable, with one
/// difference that matters: **every pattern is a path from the repository root**.
/// `.gitignore`'s `foo` matches a `foo` at any depth, which here would mean
/// walking the whole tree, including the very directories (`node_modules`) that
/// make a walk expensive. So `.env` means the repository's own `.env` and
/// nothing else, and a pattern opts into a walk by writing `**`.
public struct WorktreeSeedPattern: Sendable, Equatable {
    /// The pattern with its prefixes and suffixes removed, relative to the repository root.
    public var glob: String
    /// What to do with the paths this pattern selects. Negated patterns ignore it.
    public var action: WorktreeSeedAction
    /// Whether the pattern removes paths an earlier pattern selected (`!` prefix).
    public var isNegated: Bool
    /// Whether the pattern only matches directories (trailing `/`).
    public var directoryOnly: Bool
    /// 1-based line number in the file, so a problem can be reported where it is.
    public var line: Int

    /// Creates a pattern.
    public init(
        glob: String,
        action: WorktreeSeedAction = .copy,
        isNegated: Bool = false,
        directoryOnly: Bool = false,
        line: Int = 0
    ) {
        self.glob = glob
        self.action = action
        self.isNegated = isNegated
        self.directoryOnly = directoryOnly
        self.line = line
    }

    /// The pattern's segments, for matching one directory level at a time.
    public var segments: [String] {
        glob.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

/// A line a `.worktreeinclude` file could not be read as a pattern.
///
/// These are reported rather than thrown one at a time: a configuration file
/// should tell its author about every mistake in one pass.
public struct WorktreeSeedProblem: Error, Sendable, Equatable, CustomStringConvertible {
    /// Why the line was rejected.
    public enum Reason: Sendable, Equatable {
        /// A leading `/`. Patterns are already repository-relative, so it means nothing here.
        case leadingSlash
        /// A leading `~`. Seeding never reaches outside the repository.
        case homeRelative
        /// A `..` segment. The same reason.
        case escapesRepository
        /// `!link …`. A negation removes paths; it has no action to take on them.
        case negatedActionKeyword
        /// Only separators or escapes were left after the prefixes were removed.
        case emptyPattern
    }

    /// The line, as written, with surrounding whitespace removed.
    public var text: String
    /// 1-based line number.
    public var line: Int
    /// Why it was rejected.
    public var reason: Reason

    /// Creates a problem.
    public init(text: String, line: Int, reason: Reason) {
        self.text = text
        self.line = line
        self.reason = reason
    }

    /// A message naming the line and what to write instead.
    public var description: String {
        let advice: String
        switch reason {
        case .leadingSlash:
            advice = "patterns are relative to the repository root already, so drop the leading slash"
        case .homeRelative:
            advice = "a pattern cannot start at the home directory; seeding stays inside the repository"
        case .escapesRepository:
            advice = "a pattern cannot contain '..'; seeding stays inside the repository"
        case .negatedActionKeyword:
            advice = "'!' removes paths, so it takes no action keyword; write '!\(strippedKeyword())'"
        case .emptyPattern:
            advice = "nothing is left of this line to match with"
        }
        return "line \(line): \(text.isEmpty ? "(blank)" : text): \(advice)"
    }

    private func strippedKeyword() -> String {
        var rest = Substring(text).dropFirst()
        for action in WorktreeSeedAction.allCases where rest.hasPrefix(action.rawValue) {
            let after = rest.dropFirst(action.rawValue.count)
            if after.first == " " || after.first == "\t" {
                rest = after.drop(while: { $0 == " " || $0 == "\t" })
                break
            }
        }
        return String(rest)
    }
}

extension WorktreeSeedPattern {
    /// Reads one line.
    ///
    /// Returns `nil` for a blank line and for a comment (`#`). Everything else is
    /// either a pattern or a problem.
    ///
    /// Order of the prefixes: `!` first, then an action keyword (`link `), then
    /// a single `\` escape for a pattern that really does start with `!`, `#` or
    /// an action keyword. An action keyword is only a keyword when a pattern
    /// follows it on the same line, so a bare `link` is a path named `link`.
    public static func parse(line text: String, number: Int) -> Result<WorktreeSeedPattern?, WorktreeSeedProblem> {
        let trimmed = trimmingUnescapedTrailingWhitespace(text)
        guard !trimmed.isEmpty else { return .success(nil) }
        if trimmed.hasPrefix("#") { return .success(nil) }

        func problem(_ reason: WorktreeSeedProblem.Reason) -> Result<WorktreeSeedPattern?, WorktreeSeedProblem> {
            .failure(WorktreeSeedProblem(text: trimmed, line: number, reason: reason))
        }

        var rest = Substring(trimmed)
        var isNegated = false
        if rest.hasPrefix("!") {
            isNegated = true
            rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }

        var action = WorktreeSeedAction.copy
        var sawKeyword = false
        for candidate in WorktreeSeedAction.allCases where rest.hasPrefix(candidate.rawValue) {
            let after = rest.dropFirst(candidate.rawValue.count)
            guard after.first == " " || after.first == "\t" else { continue }
            action = candidate
            sawKeyword = true
            rest = after.drop(while: { $0 == " " || $0 == "\t" })
            break
        }
        if sawKeyword, isNegated { return problem(.negatedActionKeyword) }

        if rest.hasPrefix("\\") {
            let escaped = rest.dropFirst()
            if escaped.isEmpty { return problem(.emptyPattern) }
            let escapesParserPrefix = escaped.hasPrefix("!")
                || escaped.hasPrefix("#")
                || WorktreeSeedAction.allCases.contains { candidate in
                    guard escaped.hasPrefix(candidate.rawValue) else { return false }
                    let after = escaped.dropFirst(candidate.rawValue.count)
                    return after.first == " " || after.first == "\t"
                }
            if escapesParserPrefix { rest = escaped }
        }

        if rest.hasPrefix("/") { return problem(.leadingSlash) }
        if rest.hasPrefix("~") { return problem(.homeRelative) }

        var directoryOnly = false
        while rest.hasSuffix("/") {
            directoryOnly = true
            rest = rest.dropLast()
        }

        let glob = String(rest)
        if glob.isEmpty { return problem(.emptyPattern) }
        let segments = glob.split(separator: "/", omittingEmptySubsequences: true)
        if segments.isEmpty { return problem(.emptyPattern) }
        if segments.contains(where: { $0 == ".." }) { return problem(.escapesRepository) }

        return .success(
            WorktreeSeedPattern(
                glob: segments.joined(separator: "/"),
                action: action,
                isNegated: isNegated,
                directoryOnly: directoryOnly,
                line: number
            )
        )
    }

    /// Removes trailing spaces and tabs, keeping one that a `\` escaped.
    ///
    /// A filename really can end in a space, and `.gitignore` spells that
    /// `"foo\ "`. Leading whitespace is removed unconditionally: a pattern
    /// indented for readability should still match.
    private static func trimmingUnescapedTrailingWhitespace(_ text: String) -> String {
        var characters = Array(text.drop(while: { $0 == " " || $0 == "\t" }))
        while let last = characters.last, last == " " || last == "\t" {
            let escapes = characters.dropLast().reversed().prefix(while: { $0 == "\\" }).count
            if escapes % 2 == 1 {
                characters.remove(at: characters.count - 2)
                break
            }
            characters.removeLast()
        }
        return String(characters)
    }
}

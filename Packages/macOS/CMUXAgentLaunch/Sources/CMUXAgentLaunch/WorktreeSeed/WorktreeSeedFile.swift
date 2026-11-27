import Foundation

/// A parsed `.worktreeinclude`.
///
/// Parsing never fails as a whole. A file with three good lines and one bad one
/// yields three patterns and one problem, so seeding can proceed on what was
/// understood while still telling the author what to fix. Whether a problem is
/// fatal is the caller's decision, not the parser's.
public struct WorktreeSeedFile: Sendable, Equatable {
    /// The name the repository root uses for this file.
    public static let fileName = ".worktreeinclude"

    /// Patterns in file order. Order decides negation: the last match wins.
    public var patterns: [WorktreeSeedPattern]
    /// Lines that could not be read.
    public var problems: [WorktreeSeedProblem]

    /// Creates a file.
    public init(patterns: [WorktreeSeedPattern] = [], problems: [WorktreeSeedProblem] = []) {
        self.patterns = patterns
        self.problems = problems
    }

    /// Whether the file selects nothing, which is worth saying out loud: an empty
    /// or all-comment file and a missing file lead to the same silent no-op.
    public var isEmpty: Bool { patterns.isEmpty }

    /// Reads the file's text.
    ///
    /// Line endings may be LF, CRLF or a lone CR. Splitting has to name all
    /// three: Swift reads `\r\n` as one `Character`, so splitting on `\n` alone
    /// leaves the CRLF intact and the whole file becomes one line.
    public static func parse(_ text: String) -> WorktreeSeedFile {
        var patterns: [WorktreeSeedPattern] = []
        var problems: [WorktreeSeedProblem] = []
        var number = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: isLineBreak) {
            number += 1
            switch WorktreeSeedPattern.parse(line: String(line), number: number) {
            case .success(let pattern?):
                patterns.append(pattern)
            case .success(nil):
                continue
            case .failure(let problem):
                problems.append(problem)
            }
        }
        return WorktreeSeedFile(patterns: patterns, problems: problems)
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }
}

public import Foundation

/// A GitHub issue, pull request, or commit that a terminal token names without
/// spelling out a URL.
public struct TerminalGitHubReference: Equatable, Sendable {
    /// What the token points at on GitHub.
    public enum Kind: Equatable, Sendable {
        /// An issue or pull request number. GitHub redirects `/issues/<n>` to
        /// the pull request when the number is one, so both use this case.
        case issueOrPullRequest(number: Int)
        /// A commit, abbreviated or full length.
        case commit(sha: String)
    }

    /// What the token points at.
    public let kind: Kind
    /// The `owner/name` repository the reference resolves against.
    public let repositorySlug: String
    /// The token as it appeared in the terminal, after punctuation trimming.
    public let rawToken: String

    /// The `github.com` URL for the reference.
    public var url: URL {
        // Every component is validated to unreserved characters before a
        // reference is constructed, so this string is always a valid URL.
        let suffix: String
        switch kind {
        case .issueOrPullRequest(let number):
            suffix = "issues/\(number)"
        case .commit(let sha):
            suffix = "commit/\(sha)"
        }
        return URL(string: "https://github.com/\(repositorySlug)/\(suffix)")!
    }
}

/// Recognizes GitHub references that agents and tools write without a URL:
/// `#15173`, `owner/repo#847`, `GH-1234`, and commit SHAs.
///
/// Cmd-click resolution tries filesystem paths first, so this detector only
/// sees tokens that are not local files. It stays deliberately strict, because
/// a false positive sends a click to the wrong place: a bare reference resolves
/// only against a known `owner/name` repository, anything carrying a URL scheme
/// is left to the terminal runtime's own link detection, and hex runs that
/// could plausibly be an ordinary number or word are not read as SHAs.
public struct TerminalGitHubReferenceDetector: Sendable {
    /// Characters stripped from the front of a token before matching.
    private static let leadingTrim = Set("([{<'\"`*_")
    /// Characters stripped from the end of a token before matching.
    private static let trailingTrim = Set(")]}>'\"`*_,.;:!?")

    /// Abbreviated SHAs only, until commit existence is checked against the
    /// repository.
    ///
    /// Git abbreviates to 7 characters and grows the prefix as a repository
    /// gets larger, so 12 covers even very large repositories. The full 40 is
    /// deliberately excluded: it is character-for-character what `sha1sum`
    /// prints, and 32 is what `md5sum` and a dashless UUID print, so accepting
    /// those lengths turns ordinary checksum output into a link to a commit
    /// that does not exist. Those lengths come back once a candidate is
    /// verified against the pane's repository.
    private static let shaLengthRange = 7...12
    /// GitHub issue numbers stay well inside nine digits.
    private static let maxIssueNumberDigits = 9

    /// Creates a detector.
    public init() {}

    /// Resolves the GitHub reference under a column of a visible terminal line.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the pointer.
    ///   - repositorySlug: The pane's `owner/name` repository, used for
    ///     references that do not name one. `nil` when the pane has no GitHub
    ///     remote.
    /// - Returns: The reference under the column, or `nil`.
    public func reference(
        inVisibleLine line: String,
        column: Int,
        repositorySlug: String?
    ) -> TerminalGitHubReference? {
        guard let segment = whitespaceSegment(of: line, containing: column) else { return nil }
        return reference(inToken: segment, repositorySlug: repositorySlug)
    }

    /// Resolves the GitHub reference a single token names.
    ///
    /// - Parameters:
    ///   - token: One whitespace-delimited token, with or without wrapping
    ///     punctuation.
    ///   - repositorySlug: The pane's `owner/name` repository, or `nil`.
    /// - Returns: The reference the token names, or `nil`.
    public func reference(
        inToken token: String,
        repositorySlug: String?
    ) -> TerminalGitHubReference? {
        guard let match = match(inToken: token) else { return nil }

        let slug: String?
        switch match.slug {
        case .explicit(let explicitSlug):
            slug = explicitSlug
        case .pane:
            slug = repositorySlug.flatMap(normalizedSlug)
        }
        guard let slug else { return nil }

        return TerminalGitHubReference(
            kind: match.kind,
            repositorySlug: slug,
            rawToken: match.rawToken
        )
    }

    /// Whether the token under a column reads as a reference but still needs the
    /// pane's repository to resolve.
    ///
    /// Callers use this to decide whether a repository lookup is worth doing at
    /// all, so an ordinary word under a cmd-click never costs a `git` call.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the pointer.
    /// - Returns: `true` when a repository would complete the reference.
    public func needsRepositorySlug(inVisibleLine line: String, column: Int) -> Bool {
        guard let segment = whitespaceSegment(of: line, containing: column) else { return false }
        return needsRepositorySlug(inToken: segment)
    }

    /// Whether the token reads as a reference but still needs the pane's
    /// repository to resolve.
    ///
    /// - Parameter token: One whitespace-delimited token.
    /// - Returns: `true` when a repository would complete the reference.
    public func needsRepositorySlug(inToken token: String) -> Bool {
        guard let match = match(inToken: token) else { return false }
        return match.slug == .pane
    }

    // MARK: - Parsing

    /// Which repository a matched token resolves against.
    private enum MatchedSlug: Equatable {
        /// The token named its own `owner/name` repository.
        case explicit(String)
        /// The token needs the pane's repository.
        case pane
    }

    /// A token that reads as a GitHub reference, before a repository is applied.
    private struct Match {
        let kind: TerminalGitHubReference.Kind
        let slug: MatchedSlug
        let rawToken: String
    }

    /// Parses a token into a reference shape, without resolving a repository.
    private func match(inToken token: String) -> Match? {
        let trimmed = trimWrappingPunctuation(token)
        guard !trimmed.isEmpty else { return nil }

        // A token with a scheme belongs to the runtime's URL detection. Reading
        // a `#123` fragment out of one would send the click somewhere else.
        guard !trimmed.contains("://") else { return nil }

        if let hashIndex = trimmed.firstIndex(of: "#") {
            let owner = String(trimmed[trimmed.startIndex..<hashIndex])
            let numberText = String(trimmed[trimmed.index(after: hashIndex)...])
            guard let number = issueNumber(numberText) else { return nil }

            let slug: MatchedSlug
            if owner.isEmpty {
                slug = .pane
            } else {
                guard let explicitSlug = normalizedSlug(owner) else { return nil }
                slug = .explicit(explicitSlug)
            }
            return Match(kind: .issueOrPullRequest(number: number), slug: slug, rawToken: trimmed)
        }

        if let number = gitHubDashNumber(trimmed) {
            return Match(kind: .issueOrPullRequest(number: number), slug: .pane, rawToken: trimmed)
        }

        if isCommitSHA(trimmed) {
            return Match(kind: .commit(sha: trimmed), slug: .pane, rawToken: trimmed)
        }

        return nil
    }

    // MARK: - Tokenizing

    /// The whitespace-delimited segment covering a zero-based column.
    private func whitespaceSegment(of line: String, containing column: Int) -> String? {
        guard column >= 0 else { return nil }
        let characters = Array(line)
        guard column < characters.count, !characters[column].isWhitespace else { return nil }

        var start = column
        while start > 0, !characters[start - 1].isWhitespace {
            start -= 1
        }
        var end = column
        while end + 1 < characters.count, !characters[end + 1].isWhitespace {
            end += 1
        }
        return String(characters[start...end])
    }

    /// The token with wrapping quotes, brackets, and sentence punctuation removed.
    private func trimWrappingPunctuation(_ token: String) -> String {
        var slice = Substring(token)
        while let first = slice.first, Self.leadingTrim.contains(first) {
            slice = slice.dropFirst()
        }
        while let last = slice.last, Self.trailingTrim.contains(last) {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    // MARK: - Matching

    /// The issue number a digit run names, rejecting zero, leading zeros, and
    /// runs too long to be a real number.
    private func issueNumber(_ text: String) -> Int? {
        guard !text.isEmpty,
              text.count <= Self.maxIssueNumberDigits,
              text.allSatisfy(\.isASCIIDigit),
              text.first != "0",
              let number = Int(text),
              number > 0 else { return nil }
        return number
    }

    /// The issue number in the `GH-1234` form changelogs and commit trailers use.
    private func gitHubDashNumber(_ token: String) -> Int? {
        let prefix = token.prefix(3)
        guard prefix.count == 3, prefix.lowercased() == "gh-" else { return nil }
        return issueNumber(String(token.dropFirst(3)))
    }

    /// Whether a token reads as an abbreviated or full commit SHA.
    ///
    /// Requires both a digit and a letter. A 7+ character hex run that is all
    /// digits is far more likely to be an ordinary number, and one that is all
    /// letters is far more likely to be a word such as `deadbeef`. This drops a
    /// small share of genuine short SHAs in exchange for not sending clicks on
    /// numbers and words to GitHub.
    ///
    /// Length is bounded to the abbreviated range as well, so checksum output
    /// is not mistaken for a commit. See ``shaLengthRange``.
    private func isCommitSHA(_ token: String) -> Bool {
        guard Self.shaLengthRange.contains(token.count) else { return false }
        var sawDigit = false
        var sawLetter = false
        for character in token {
            if character.isASCIIDigit {
                sawDigit = true
            } else if character.isLowercaseHexLetter {
                sawLetter = true
            } else {
                return false
            }
        }
        return sawDigit && sawLetter
    }

    /// The `owner/name` slug a candidate names, dropping a trailing `.git`, or
    /// `nil` when it is not a two-component repository path.
    private func normalizedSlug(_ candidate: String) -> String? {
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let owner = String(components[0])
        var name = String(components[1])
        if name.hasSuffix(".git") {
            name.removeLast(4)
        }
        guard isSlugComponent(owner), isSlugComponent(name) else { return nil }
        return "\(owner)/\(name)"
    }

    /// Whether a slug component matches what GitHub allows in an owner or
    /// repository name.
    private func isSlugComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component.count <= 100 else { return false }
        guard component != ".", component != ".." else { return false }
        return component.allSatisfy { character in
            character.isASCIIDigit
                || ("a"..."z").contains(character)
                || ("A"..."Z").contains(character)
                || character == "-"
                || character == "_"
                || character == "."
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isLowercaseHexLetter: Bool { ("a"..."f").contains(self) }
}

public import Foundation

/// Which physical row completes a hard-wrapped path continuation.
public enum TerminalWrapDirection: Sendable {
    /// The clicked token starts with `/`; its continuation, if any, is on
    /// the row below (the token is the start of an absolute path that ran
    /// out of columns).
    case next
    /// The clicked token doesn't start with `/`; its continuation, if any,
    /// is on the row above (the token is the tail of a path that wrapped
    /// onto this row).
    case previous
}

/// A hard-wrapped path token detected on the clicked row, awaiting the
/// adjacent row before it can resolve to an existing file.
///
/// Returned by ``TerminalPathResolver/wrappedPathSeed(in:column:cwd:)``.
/// Callers only branch on ``direction`` to pick which adjacent row to read;
/// every other tokenization detail stays private to the package.
public struct TerminalWrappedPathSeed: Sendable {
    public let direction: TerminalWrapDirection
    let token: String
}

/// A hard-wrapped path candidate resolved against an adjacent row, ready to
/// be opened.
///
/// Returned by
/// ``TerminalPathResolver/resolveWrappedCandidate(seed:adjacentRow:cwd:)``.
public struct TerminalWrappedPathResolution: Sendable, Equatable {
    /// The existing standardized file-system path to open.
    public let path: String
    /// The exact-match key for correlating this candidate against a native
    /// Ghostty `open_url` callback for the same click. Comparisons must be
    /// exact; substring matching can misattribute an unrelated native link.
    public let nativeMatchKey: String

    public init(path: String, nativeMatchKey: String) {
        self.path = path
        self.nativeMatchKey = nativeMatchKey
    }
}

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against the surface cwd, standardizes, and probes in order.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public struct TerminalPathResolver: Sendable {
    /// Maximum characters in a wrapped-path token or adjacent-row fragment.
    /// Mirrors POSIX `PATH_MAX` so a pathological row can't make
    /// tokenization unbounded.
    private static let maxWrappedFragmentLength = 1024
    /// Maximum leading ASCII spaces tolerated between a logical line's
    /// start and a wrapped-path fragment.
    private static let maxContinuationIndentation = 16

    private let fileExists: @Sendable (String) -> Bool

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameter fileExists: The file-existence capability; defaults to the
    ///   real file system.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.fileExists = fileExists
    }

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, standardized, and probed
    /// in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveQuicklookPath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var seenPaths: Set<String> = []
        for token in trimmed.pathResolutionCandidates() {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            let expandedToken = (normalizedToken as NSString).expandingTildeInPath
            let candidatePath: String
            if expandedToken.hasPrefix("/") {
                candidatePath = expandedToken
            } else {
                guard let cwd, !cwd.isEmpty else { continue }
                candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
            }

            let standardizedPath = (candidatePath as NSString).standardizingPath
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            if fileExists(standardizedPath) {
                return standardizedPath
            }
        }

        return nil
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let resolvedPath = resolveQuicklookPath(rawToken, cwd: cwd) {
                return (rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed)?.scheme == nil else { return nil }
        return resolveQuicklookPath(trimmed, cwd: cwd)
    }

    /// Detects a hard-wrapped absolute-path token touching `column` on
    /// `clickedRow`, deferring to the adjacent row for confirmation.
    ///
    /// Row-local resolution always wins: if
    /// ``resolveVisibleLinePath(_:column:cwd:)`` already resolves a path on
    /// `clickedRow`, this returns `nil` so callers fall back to that result
    /// instead of attempting a cross-row join. Non-ASCII rows also return
    /// `nil` (fail-closed): `column` is a terminal-cell index, which only
    /// lines up with `String` character indices when every character
    /// occupies exactly one cell.
    ///
    /// - Parameters:
    ///   - clickedRow: The full text of the row under the cursor.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: A seed naming which adjacent row would complete the
    ///   token, or `nil` when no wrapped-path candidate touches `column`.
    public func wrappedPathSeed(
        in clickedRow: String,
        column: Int,
        cwd: String
    ) -> TerminalWrappedPathSeed? {
        guard resolveVisibleLinePath(clickedRow, column: column, cwd: cwd) == nil else {
            return nil
        }
        guard let match = clickedRow.wrapContinuationToken(
            atColumn: column,
            maxIndentation: Self.maxContinuationIndentation
        ), match.token.count <= Self.maxWrappedFragmentLength else {
            return nil
        }
        return TerminalWrappedPathSeed(direction: match.direction, token: match.token)
    }

    /// Resolves a ``TerminalWrappedPathSeed`` against the adjacent row it
    /// named, returning the single existing path candidate, if any.
    ///
    /// Guards against coincidental adjacency: if the adjacent row's own
    /// fragment already resolves to an existing path by itself, this
    /// returns `nil` rather than joining it to the clicked token. Only
    /// absolute-path candidates (`/`-prefixed) are considered.
    ///
    /// - Parameters:
    ///   - seed: The seed returned by ``wrappedPathSeed(in:column:cwd:)``.
    ///   - adjacentRow: The full text of the row named by `seed.direction`.
    ///   - cwd: The surface's working directory.
    /// - Returns: The resolved candidate, or `nil` when no existing
    ///   absolute path joins the seed token to the adjacent row.
    public func resolveWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        adjacentRow: String,
        cwd: String
    ) -> TerminalWrappedPathResolution? {
        let fragment: String?
        switch seed.direction {
        case .next:
            fragment = adjacentRow.leadingContinuationFragment(maxIndentation: Self.maxContinuationIndentation)
        case .previous:
            fragment = adjacentRow.trailingContinuationFragment()
        }

        guard let fragment, fragment.count <= Self.maxWrappedFragmentLength else { return nil }
        guard resolveQuicklookPath(fragment, cwd: cwd) == nil else { return nil }

        let candidate: String
        switch seed.direction {
        case .next:
            candidate = seed.token + fragment
        case .previous:
            candidate = fragment + seed.token
        }

        guard candidate.hasPrefix("/"),
              candidate.count <= Self.maxWrappedFragmentLength * 2 else {
            return nil
        }

        let standardizedPath = (candidate as NSString).standardizingPath
        guard fileExists(standardizedPath) else { return nil }

        return TerminalWrappedPathResolution(
            path: standardizedPath,
            nativeMatchKey: seed.token.normalizedTerminalWrapMatchKey()
        )
    }
}

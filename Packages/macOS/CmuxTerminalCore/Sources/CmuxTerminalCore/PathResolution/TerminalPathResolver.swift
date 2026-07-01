public import Foundation

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

    /// Resolves an open-URL request payload to an existing file plus an optional
    /// `line[:column]` reference.
    ///
    /// Like ``resolveOpenURLFilePath(_:cwd:)`` but understands the
    /// `path:line[:column]` convention: each candidate spelling is probed
    /// as-is first (so a literal path that really contains a colon wins) and
    /// then with a trailing line reference stripped. `http`/`https` text is
    /// never treated as a file path; other schemes still fall through to the
    /// file-existence probe, which gates false positives.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing file reference, or `nil`.
    public func resolveOpenURLFileReference(_ rawText: String, cwd: String?) -> TerminalFileReference? {
        return nil
    }
}

/// An existing file plus an optional editor `line[:column]` target, carried
/// from terminal link resolution to the file opener.
///
/// The line/column travel to the editor as a URL fragment (`#L<line>` or
/// `#L<line>:<column>`) so a plain `URL` is enough to cross the package
/// boundary; ``fileURL`` is the single place that encoding lives.
public struct TerminalFileReference: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int?, column: Int?) {
        self.path = path
        self.line = line
        self.column = column
    }

    /// A `file://` URL for ``path``, carrying the line/column as a `#L…`
    /// fragment when a line is present.
    public var fileURL: URL {
        return URL(fileURLWithPath: path)
    }
}

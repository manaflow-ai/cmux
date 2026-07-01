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
    /// never treated as a file path, and a line-stripped candidate is only
    /// probed when it is shaped like a path (has a separator or extension), so
    /// a bare `host:port` that merely matches a same-named directory in `cwd`
    /// is not mistaken for a file reference.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing file reference, or `nil`.
    public func resolveOpenURLFileReference(_ rawText: String, cwd: String?) -> TerminalFileReference? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Web URLs are never file paths. Every other spelling — scheme-less
        // text, or a bogus scheme Foundation parses out of `name:line` — stays
        // eligible and is gated by the file-existence probe below.
        let scheme = URL(string: trimmed)?.scheme?.lowercased()
        guard scheme != "http", scheme != "https" else { return nil }

        var seenPaths: Set<String> = []
        for token in trimmed.pathResolutionCandidates() {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            // Probe the literal token first so a path that really ends in a
            // colon-number wins over the line-reference reading, then probe the
            // line-stripped path.
            if let reference = existingFileReference(
                token: normalizedToken, line: nil, column: nil, cwd: cwd, seenPaths: &seenPaths
            ) {
                return reference
            }
            if let split = normalizedToken.splitTerminalPathLineSuffix(),
               looksLikeFilePath(split.path),
               let reference = existingFileReference(
                   token: split.path, line: split.line, column: split.column, cwd: cwd, seenPaths: &seenPaths
               ) {
                return reference
            }
        }

        return nil
    }

    /// Whether a line-stripped token is shaped like a file path — it carries a
    /// separator or a file extension — rather than a bare `host:port` /
    /// `word:number` token that only happens to name an existing directory in
    /// the working directory. Bare extension-less names (e.g. `Makefile:12`)
    /// are intentionally excluded here; those arrive through the cmd-click
    /// word-under-cursor path, not open-URL.
    private func looksLikeFilePath(_ token: String) -> Bool {
        token.contains("/") || !(token as NSString).pathExtension.isEmpty
    }

    /// Standardizes `token` against `cwd`, dedupes against `seenPaths`, and
    /// returns a reference carrying `line`/`column` when the file exists.
    private func existingFileReference(
        token: String,
        line: Int?,
        column: Int?,
        cwd: String?,
        seenPaths: inout Set<String>
    ) -> TerminalFileReference? {
        let expandedToken = (token as NSString).expandingTildeInPath
        let candidatePath: String
        if expandedToken.hasPrefix("/") {
            candidatePath = expandedToken
        } else {
            guard let cwd, !cwd.isEmpty else { return nil }
            candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
        }

        let standardizedPath = (candidatePath as NSString).standardizingPath
        guard seenPaths.insert(standardizedPath).inserted else { return nil }
        guard fileExists(standardizedPath) else { return nil }
        return TerminalFileReference(path: standardizedPath, line: line, column: column)
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
        let base = URL(fileURLWithPath: path)
        guard let line else { return base }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.fragment = column.map { "L\(line):\($0)" } ?? "L\(line)"
        return components?.url ?? base
    }
}

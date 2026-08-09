public import Foundation

/// Which physical row completes a hard-wrapped path continuation.
public enum TerminalWrapDirection: Sendable, Hashable {
    /// The clicked token starts with `/`; its continuation, if any, is on
    /// the row below (the token is the start of an absolute path that ran
    /// out of columns).
    case next
    /// The clicked token doesn't start with `/`; its continuation, if any,
    /// is on the row above (the token is the tail of a path that wrapped
    /// onto this row).
    case previous
}

/// Why one direction of a wrapped-path join succeeded or failed, for
/// diagnostics. See
/// ``TerminalPathResolver/diagnoseWrappedCandidate(seed:previousRow:nextRow:cwd:)``.
public enum TerminalWrappedCandidateDirectionOutcome: Sendable, Equatable {
    /// This direction produced the resolved candidate.
    case succeeded(TerminalWrappedPathResolution)
    /// The adjacent row had no token at its leading/trailing edge to extract.
    case noFragment
    /// The extracted fragment alone exceeds the per-fragment length cap.
    case fragmentTooLong
    /// The token and fragment lengths sum past the joined-candidate cap.
    case candidateTooLong
    /// The piece leading this direction's join (the clicked token for
    /// `.next`, the adjacent fragment for `.previous`) isn't itself
    /// shaped like a path prefix.
    case leadingPieceNotPathPrefixShaped
    /// The adjacent fragment already resolves to an existing path by
    /// itself, so joining it would be coincidental, not a continuation.
    case fragmentAloneExists
    /// The joined candidate isn't shaped like a real path (mirroring
    /// Ghostty's `bare_relative_path_branch`).
    case candidateNotPathShaped
    /// The joined, cwd-resolved candidate doesn't exist on disk.
    case candidateDoesNotExist
}

/// A hard-wrapped path token detected on the clicked row, awaiting one or
/// both adjacent rows before it can resolve to an existing file.
///
/// Returned by ``TerminalPathResolver/wrappedPathSeed(in:column:cwd:)``.
/// Callers read whichever adjacent row(s) ``directions`` names — one row
/// for a single direction, both rows when it names two (ambiguous
/// bare-relative token) — and pass whatever they read to
/// ``TerminalPathResolver/resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``.
/// Every other tokenization detail stays private to the package.
public struct TerminalWrappedPathSeed: Sendable {
    /// The adjacent row(s) that could complete this token: one entry for an
    /// unambiguous token, two (`[.previous, .next]`) for a bare-relative
    /// token touching both boundaries.
    public let directions: [TerminalWrapDirection]
    let token: String
    /// The clicked token's column range on the clicked row (half-open),
    /// carried through to ``TerminalWrappedPathResolution/cellSpans`` so a
    /// caller never needs to re-tokenize to find where to underline it.
    let tokenStartColumn: Int
    let tokenEndColumn: Int
}

/// (B) ExternalHover — one cell span to underline, relative to the clicked
/// row. Exactly two are ever produced for a resolved wrapped-path
/// candidate: the clicked token's own span (`rowOffsetFromClicked == 0`)
/// and the winning direction's adjacent-row fragment span
/// (`rowOffsetFromClicked == -1` for `.previous`, `+1` for `.next`) — never
/// a rejected direction's span, matching
/// ``TerminalWrappedPathResolution/nativeMatchKeys``'s same winning-only
/// rule.
///
/// A caller materializes these into absolute viewport ranges by adding the
/// clicked row's own viewport row to `rowOffsetFromClicked` — this type
/// intentionally carries no absolute row itself, since that would require
/// re-deriving it correctly at every call site instead of once.
public struct TerminalWrappedPathCellSpan: Sendable, Equatable {
    public let rowOffsetFromClicked: Int
    /// Inclusive start column.
    public let startColumn: Int
    /// Exclusive end column (half-open).
    public let endColumn: Int

    public init(rowOffsetFromClicked: Int, startColumn: Int, endColumn: Int) {
        self.rowOffsetFromClicked = rowOffsetFromClicked
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}

/// A hard-wrapped path candidate resolved against an adjacent row, ready to
/// be opened.
///
/// Returned by
/// ``TerminalPathResolver/resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``.
public struct TerminalWrappedPathResolution: Sendable, Equatable {
    /// The existing standardized file-system path to open.
    public let path: String
    /// Ordered, deduplicated, at most 3 exact-match keys for correlating
    /// this candidate against a native Ghostty `open_url` callback for the
    /// same click:
    ///
    /// 1. The raw, fully joined candidate text (clicked token and adjacent
    ///    fragment concatenated in the order used to build ``path``).
    /// 2. The clicked row's raw fragment (the token alone).
    /// 3. The winning direction's adjacent row's raw fragment alone.
    ///
    /// Only the *winning* direction's constituents are ever included —
    /// never a rejected direction's fragment, which would widen the set of
    /// native text this candidate can claim beyond what this click actually
    /// resolved. Empty entries are dropped and duplicates collapsed, so the
    /// array can have fewer than 3 entries.
    ///
    /// "Raw" means the terminal-visible representation Ghostty's own
    /// callback reports — not a filesystem-oriented path (no quote
    /// removal, tilde expansion, or cwd resolution); only whitespace and a
    /// trailing NUL are normalized, matching the callback side. Ghostty's
    /// own hard-wrap link continuation (`link_wrap.zig`) can report either
    /// the whole joined match text or just a same-row independent link
    /// depending on how it parses the row, so a single fixed key can't
    /// reliably equal every real callback shape for the same click.
    /// Comparisons must be exact; substring matching can misattribute an
    /// unrelated native link.
    public let nativeMatchKeys: [String]

    /// (B) ExternalHover — the clicked token's span plus the winning
    /// direction's adjacent-row fragment span, for underlining without
    /// re-tokenizing. Exactly 2 entries when resolved through
    /// ``TerminalPathResolver/resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``;
    /// empty for a `TerminalWrappedPathResolution` constructed directly
    /// (e.g. in existing click-arbitrator tests that only need `path`/
    /// `nativeMatchKeys`).
    public let cellSpans: [TerminalWrappedPathCellSpan]

    public init(
        path: String,
        nativeMatchKeys: [String],
        cellSpans: [TerminalWrappedPathCellSpan] = []
    ) {
        self.path = path
        self.nativeMatchKeys = nativeMatchKeys
        self.cellSpans = cellSpans
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
    /// review-slash-boundary-and-codex-comparison.md §2's row1/leading-side
    /// fix (issue #8810 bug A): a row-local hit no longer unconditionally
    /// wins. Token/range extraction now runs BEFORE the row-local check, and
    /// row-local resolving still returns `nil` here in every case EXCEPT one
    /// narrow exception — an explicit `/` continuation seam — mirroring
    /// Ghostty's own `link_wrap.zig` treating a trailing `/` as stronger
    /// continuation evidence than ordinary mid-word adjacency.
    ///
    /// The exception requires: the match has a `.next` direction (which,
    /// by ``String/wrapContinuationToken(atColumn:maxIndentation:)``'s own
    /// construction, already implies the token touches the row's trailing
    /// boundary — condition 3 in the design doc is structurally guaranteed
    /// by condition 1, not checked separately), and the clicked token
    /// itself ends with `/`. Meeting this only produces a PROVISIONAL
    /// seed: the actual decision still requires the adjacent row's
    /// fragment to be unindented and the exact joined candidate to exist
    /// (``resolveSingleDirection(_:seed:adjacentRow:cwd:)``'s matching
    /// `explicitSlashSeam` bypass of the `fragmentAloneExists` guard). If
    /// that later join fails, ``resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``
    /// returns `nil` exactly as if this method had returned `nil` directly,
    /// so a caller's existing row-local fallback (triggered by a `nil`
    /// candidate, not by a `nil` seed specifically) still applies
    /// identically either way.
    public func wrappedPathSeed(
        in clickedRow: String,
        column: Int,
        cwd: String
    ) -> TerminalWrappedPathSeed? {
        guard let match = clickedRow.wrapContinuationToken(
            atColumn: column,
            maxIndentation: Self.maxContinuationIndentation
        ), match.token.count <= Self.maxWrappedFragmentLength else {
            return nil
        }

        if resolveVisibleLinePath(clickedRow, column: column, cwd: cwd) != nil {
            guard match.directions.contains(.next), match.token.hasSuffix("/") else {
                return nil
            }
        }

        return TerminalWrappedPathSeed(
            directions: match.directions,
            token: match.token,
            tokenStartColumn: match.startColumn,
            tokenEndColumn: match.endColumn
        )
    }

    /// DEBUG dogfood diagnostic for why ``wrappedPathSeed(in:column:cwd:)``
    /// returned `nil` for `column` on `clickedRow` — issue #8810 bug B,
    /// review §"次に確認すべきもの" item 1. Purely classification: never
    /// called by ``wrappedPathSeed(in:column:cwd:)`` itself and never
    /// changes what it decides. Buckets are checked in the same order
    /// ``wrappedPathSeed(in:column:cwd:)`` itself would hit them.
    public func diagnoseSeedAbsence(in clickedRow: String, column: Int, cwd: String) -> String {
        let characters = Array(clickedRow)
        guard !characters.isEmpty, column >= 0, column < characters.count else {
            return "columnOutOfBounds"
        }
        guard clickedRow.unicodeScalars.allSatisfy(\.isASCII) else {
            return "nonASCIIRow"
        }
        guard let match = clickedRow.wrapContinuationToken(
            atColumn: column,
            maxIndentation: Self.maxContinuationIndentation
        ) else {
            return "noBoundaryTouched"
        }
        guard match.token.count <= Self.maxWrappedFragmentLength else {
            return "tokenTooLong"
        }
        if resolveVisibleLinePath(clickedRow, column: column, cwd: cwd) != nil {
            return "rowLocalHitNotExplicitSlashSeam"
        }
        return "unknown"
    }

    /// Resolves a ``TerminalWrappedPathSeed`` against the adjacent row(s)
    /// its `directions` named, returning the single existing path
    /// candidate, if any.
    ///
    /// Pass whichever row(s) the caller read for `seed.directions`: only
    /// `previousRow` for a `.previous`-only seed, only `nextRow` for a
    /// `.next`-only seed, or both for an ambiguous bare-relative seed. Each
    /// named direction is resolved fully independently (its own fragment
    /// extraction, prefix-shape guard, existence probes); this returns the
    /// result only when **exactly one** direction succeeds. Zero
    /// successes means no candidate; two successes means the click is
    /// ambiguous between two equally-valid joins (even if they'd standardize
    /// to the same path) and this deliberately still returns `nil` rather
    /// than guess.
    ///
    /// Guards against coincidental adjacency per direction: if that
    /// direction's own adjacent fragment already resolves to an existing
    /// path by itself, that direction doesn't count as a success.
    ///
    /// Absolute candidates (`/`-prefixed) are always considered. A relative
    /// candidate is considered only when the whole joined candidate is
    /// path-shaped (an explicit relative marker, or both containing `/`
    /// and having a dotted leaf — mirroring Ghostty's own
    /// `bare_relative_path_branch` shape, `ghostty/src/config/url.zig`)
    /// *and* the fragment leading that direction's join (the clicked token
    /// for `.next`, the adjacent row's fragment for `.previous`) is itself
    /// shaped like a path prefix (an explicit marker, or contains `/`).
    /// Without the second check, two unrelated bare words that happen to
    /// concatenate into an existing relative path (e.g. adjacent row
    /// `foo`, clicked token `bar`, with `cwd/foobar` existing) would
    /// false-positive: none of the other guards (per-fragment existence,
    /// ASCII, single-candidate, A-B-A) reason about whether the join is a
    /// real path shape.
    ///
    /// This never over-probes the filesystem: at most one existence probe
    /// for the adjacent fragment alone and one for the joined candidate,
    /// per direction actually attempted (so at most 4 total when both
    /// directions are ambiguous) — never `resolveQuicklookPath`'s
    /// multi-variant probing.
    ///
    /// A relative candidate resolves against `cwd` (matching
    /// ``resolveQuicklookPath(_:cwd:)``'s own expansion) before the
    /// existence probe, and ``TerminalWrappedPathResolution/path`` is
    /// always that resolved, standardized absolute path — never the raw
    /// relative string — so a caller reopening it later can't have it
    /// reinterpreted against a different working directory.
    ///
    /// - Parameters:
    ///   - seed: The seed returned by ``wrappedPathSeed(in:column:cwd:)``.
    ///   - previousRow: The row above the clicked row, if `seed.directions`
    ///     names `.previous`; otherwise ignored.
    ///   - nextRow: The row below the clicked row, if `seed.directions`
    ///     names `.next`; otherwise ignored.
    ///   - cwd: The surface's working directory.
    /// - Returns: The resolved candidate when exactly one direction
    ///   succeeds; `nil` when zero or both do.
    public func resolveWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        previousRow: String?,
        nextRow: String?,
        cwd: String
    ) -> TerminalWrappedPathResolution? {
        let outcomes = diagnoseWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd)
        let successes = outcomes.values.compactMap { outcome -> TerminalWrappedPathResolution? in
            if case .succeeded(let resolution) = outcome { return resolution }
            return nil
        }
        guard successes.count == 1 else { return nil }
        return successes[0]
    }

    /// Runs the same independent-per-direction resolution as
    /// ``resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)`` but
    /// returns *why* each named direction succeeded or failed, instead of
    /// collapsing straight to a single optional result.
    ///
    /// Exists for diagnostics: `noCandidate` alone doesn't say which of the
    /// five independent guards (fragment extraction, length, leading-piece
    /// prefix shape, fragment-alone existence, candidate shape, candidate
    /// existence) rejected an otherwise-correct read. Callers doing the
    /// real open should keep using
    /// ``resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)`` — this
    /// makes the same decision, just with its reasoning kept instead of
    /// discarded, so it costs no extra filesystem probes.
    ///
    /// - Returns: An entry only for each direction `seed.directions` names
    ///   *and* a corresponding row was supplied; a direction named by the
    ///   seed with no row passed is simply absent (never attempted).
    public func diagnoseWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        previousRow: String?,
        nextRow: String?,
        cwd: String
    ) -> [TerminalWrapDirection: TerminalWrappedCandidateDirectionOutcome] {
        var outcomes: [TerminalWrapDirection: TerminalWrappedCandidateDirectionOutcome] = [:]

        if seed.directions.contains(.previous), let previousRow {
            outcomes[.previous] = resolveSingleDirection(.previous, seed: seed, adjacentRow: previousRow, cwd: cwd)
        }
        if seed.directions.contains(.next), let nextRow {
            outcomes[.next] = resolveSingleDirection(.next, seed: seed, adjacentRow: nextRow, cwd: cwd)
        }

        return outcomes
    }

    private func resolveSingleDirection(
        _ direction: TerminalWrapDirection,
        seed: TerminalWrappedPathSeed,
        adjacentRow: String,
        cwd: String
    ) -> TerminalWrappedCandidateDirectionOutcome {
        let token = seed.token
        let fragmentMatch: (fragment: String, startColumn: Int, endColumn: Int)?
        switch direction {
        case .next:
            fragmentMatch = adjacentRow.leadingContinuationFragmentWithRange(maxIndentation: Self.maxContinuationIndentation)
        case .previous:
            fragmentMatch = adjacentRow.trailingContinuationFragmentWithRange()
        }
        guard let fragmentMatch else { return .noFragment }
        let fragment = fragmentMatch.fragment
        guard fragment.count <= Self.maxWrappedFragmentLength else { return .fragmentTooLong }

        // The fragment sum is checked before building the joined string so
        // the length guard can't be bypassed by a pathological concatenation.
        guard token.count + fragment.count <= Self.maxWrappedFragmentLength * 2 else { return .candidateTooLong }

        let leadingPiece = direction == .next ? token : fragment
        guard leadingPiece.isWrappedPathPrefixShaped else { return .leadingPieceNotPathPrefixShaped }

        // review-slash-boundary-and-codex-comparison.md §2's row2/
        // continuation-side fix (issue #8810 bug A): an explicit `/`
        // continuation seam is stronger join evidence than ordinary
        // adjacency, so it alone bypasses the fragment-alone-existence
        // guard below — never "the fragment happens to be a directory"
        // (rejected explicitly by review §2: that would admit any
        // coincidentally-adjacent existing directory, not just a real
        // continuation). The seam is direction-specific:
        //   .next:     `token` (the leading piece) ends with `/`, AND the
        //              adjacent row's fragment starts at column 0
        //              (unindented) — the row-local/leading-side click.
        //   .previous: `fragment` (the leading piece) ends with `/`, AND
        //              the CLICKED token starts at column 0 (unindented)
        //              — the continuation/row2-side click.
        // Requiring the continuation row be unindented mirrors Ghostty's
        // own `link_wrap.zig` `startsIndependentLink`, which fail-closes
        // exactly this shape (an indented bare-relative row after `/`) as
        // indistinguishable from an unrelated adjacent list item — see
        // that function's own doc for the ambiguity this guards against
        // (`/some/dir/` followed by an indented, independently-real
        // `child.md`).
        let explicitSlashSeam: Bool
        switch direction {
        case .next:
            explicitSlashSeam = token.hasSuffix("/") && fragmentMatch.startColumn == 0
        case .previous:
            explicitSlashSeam = fragment.hasSuffix("/") && seed.tokenStartColumn == 0
        }
        if !explicitSlashSeam {
            guard probeExists(fragment, cwd: cwd) == nil else { return .fragmentAloneExists }
        }

        let candidateRaw: String
        switch direction {
        case .next:
            candidateRaw = token + fragment
        case .previous:
            candidateRaw = fragment + token
        }
        guard candidateRaw.isWrappedPathCandidateShaped else { return .candidateNotPathShaped }

        guard let standardizedPath = probeExists(candidateRaw, cwd: cwd) else { return .candidateDoesNotExist }

        var matchKeys: [String] = []
        for raw in [candidateRaw, token, fragment] {
            let key = raw.normalizedTerminalWrapMatchKey()
            guard !key.isEmpty, !matchKeys.contains(key) else { continue }
            matchKeys.append(key)
        }
        // (B) ExternalHover — the clicked token's own span, plus the
        // winning adjacent fragment's span at the appropriate row offset.
        // Order doesn't encode meaning (a caller materializes each by its
        // own rowOffsetFromClicked), but clicked-first matches this type's
        // own "clicked token, then adjacent fragment" narrative elsewhere.
        let cellSpans = [
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 0,
                startColumn: seed.tokenStartColumn,
                endColumn: seed.tokenEndColumn
            ),
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: direction == .previous ? -1 : 1,
                startColumn: fragmentMatch.startColumn,
                endColumn: fragmentMatch.endColumn
            ),
        ]
        return .succeeded(TerminalWrappedPathResolution(
            path: standardizedPath,
            nativeMatchKeys: matchKeys,
            cellSpans: cellSpans
        ))
    }

    /// A single, exact-candidate existence probe: expands `~`, resolves
    /// against `cwd` when relative, standardizes, and checks existence
    /// once. Deliberately not ``resolveQuicklookPath(_:cwd:)``, which tries
    /// multiple punctuation-trimmed variants — that would silently multiply
    /// the wrapped-candidate I/O budget past its documented per-direction
    /// probe count.
    private func probeExists(_ raw: String, cwd: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        let candidatePath: String
        if expanded.hasPrefix("/") {
            candidatePath = expanded
        } else {
            guard !cwd.isEmpty else { return nil }
            candidatePath = (cwd as NSString).appendingPathComponent(expanded)
        }
        let standardized = (candidatePath as NSString).standardizingPath
        return fileExists(standardized) ? standardized : nil
    }
}

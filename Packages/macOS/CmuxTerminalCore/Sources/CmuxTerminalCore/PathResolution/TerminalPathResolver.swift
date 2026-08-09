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

/// impl-bugB-diagnostics-v2 (review-bugB-bare-token-no-slash.md §4) —
/// which broad class a token/fragment's first or last character falls
/// into, for a permanent DEBUG log that must never carry the character
/// (or the surrounding text) itself.
public enum TerminalWrappedCharacterClass: String, Sendable, Equatable {
    case slash
    case dot
    case alphanumeric
    case whitespace
    case other
}

/// impl-bugB-diagnostics-v2 — non-raw shape summary of one token/fragment:
/// its column range plus a handful of booleans/classifications, never the
/// text itself. Safe for a permanent (non-ephemeral) DEBUG log.
public struct TerminalWrappedTokenShape: Sendable, Equatable {
    public let startColumn: Int
    public let endColumn: Int
    public let length: Int
    public let containsSlash: Bool
    public let containsDot: Bool
    public let firstCharacterClass: TerminalWrappedCharacterClass
    public let lastCharacterClass: TerminalWrappedCharacterClass

    fileprivate init(text: String, startColumn: Int, endColumn: Int) {
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.length = text.count
        self.containsSlash = text.contains("/")
        self.containsDot = text.contains(".")
        self.firstCharacterClass = text.first.map(Self.classify) ?? .other
        self.lastCharacterClass = text.last.map(Self.classify) ?? .other
    }

    private static func classify(_ character: Character) -> TerminalWrappedCharacterClass {
        if character == "/" { return .slash }
        if character == "." { return .dot }
        if character.isWhitespace { return .whitespace }
        if character.isLetter || character.isNumber { return .alphanumeric }
        return .other
    }
}

/// impl-bugB-diagnostics-v2 — one direction's shape diagnostic, computed
/// by CONTINUING past whichever guard `resolveSingleDirection` itself
/// would have stopped at (never changing what it actually decides — see
/// ``TerminalPathResolver/diagnoseCandidateShape(seed:previousRow:nextRow:cwd:gridColumns:)``'s
/// doc). `nil` fields mean that step's INPUT was unavailable (e.g. no
/// fragment extracted at all) OR unavailable in COLUMN-RANGED form (a
/// non-ASCII `.previous` adjacent row where `outcome` itself succeeded
/// only through ``String/trailingContinuationFragmentText()``'s
/// text-only fallback, design-next-round-bundle-8810.md §1) — never that
/// the check failed.
public struct TerminalWrappedDirectionShapeDiagnostic: Sendable, Equatable {
    /// The REAL decision `resolveSingleDirection` makes for this
    /// direction — identical to what `diagnoseWrappedCandidate` reports.
    /// May be `.succeeded` even when `fragmentShape` below is `nil` (the
    /// text-only fallback case above) — this field alone is the ground
    /// truth for whether the direction resolved, `fragmentShape` is
    /// purely a column-shape extra.
    public let outcome: TerminalWrappedCandidateDirectionOutcome
    public let fragmentShape: TerminalWrappedTokenShape?
    /// Whether the leading piece of this direction's join (the clicked
    /// token for `.next`, the adjacent fragment for `.previous`) is
    /// itself path-prefix-shaped — `nil` only if no COLUMN-RANGED
    /// fragment was extracted (see this type's own doc).
    public let leadingPieceIsPathPrefixShaped: Bool?
    /// Whether the joined candidate is shaped like a real path —
    /// computed even when an earlier guard (prefix shape, fragment-alone
    /// existence) would have stopped `resolveSingleDirection` first.
    public let candidateIsPathShaped: Bool?
    /// Whether the adjacent fragment resolves to an existing path by
    /// itself.
    public let fragmentAloneExists: Bool?
    /// Whether the joined, cwd-resolved candidate exists on disk.
    public let candidateExists: Bool?
}

/// impl-bugB-diagnostics-v2 — the full shape-only diagnostic snapshot for
/// one `noCandidate` abort, safe for a permanent DEBUG log (no raw row,
/// token, or fragment text anywhere in this type).
public struct TerminalWrappedCandidateShapeDiagnostic: Sendable, Equatable {
    public let cellRow: Int
    public let cellColumn: Int
    /// The stable snapshot's physical grid width — review's "同じ stable
    /// snapshot から" requirement, so a later comparison against the
    /// click-time grid can confirm they match.
    public let gridColumns: Int
    public let tokenShape: TerminalWrappedTokenShape
    public let directions: [TerminalWrapDirection: TerminalWrappedDirectionShapeDiagnostic]
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
    /// final-spec-scope-expansion-8810.md §3 — which row-local-hit state
    /// `wrappedPathSeed(in:column:cwd:columns:)` left this seed in, for
    /// the contiguous-span evaluator to route on. Internal (never
    /// exposed): only ``TerminalPathResolver`` itself constructs a seed,
    /// and only it needs to branch on this — see
    /// ``TerminalRowLocalDisposition``'s own doc for what each case
    /// means and why `evaluateContiguousSpans` must NEVER re-derive this
    /// by calling ``resolveVisibleLinePath(_:column:cwd:)`` again itself
    /// (final-spec §8 rule 1: never re-probe the clicked token).
    let disposition: TerminalRowLocalDisposition
}

/// (B) ExternalHover — one cell span to underline, relative to the clicked
/// row. Through the 2-row
/// ``TerminalPathResolver/resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``
/// overload, exactly two are ever produced: the clicked token's own span
/// (`rowOffsetFromClicked == 0`) and the winning direction's adjacent-row
/// fragment span (`rowOffsetFromClicked == -1` for `.previous`, `+1` for
/// `.next`). Through the geometry-aware, window-based
/// ``TerminalPathResolver/resolveWrappedCandidate(seed:window:cwd:geometry:)``
/// overload, one entry is produced per row in the winning contiguous span
/// (final-spec-scope-expansion-8810.md §4) — up to ``TerminalWrapGeometry``'s
/// `maxWrappedRows` (4) — clicked row first, then the rest in ascending
/// row order, which degenerates to the exact 2-entry, 2-row shape above
/// when the winning span happens to be 2 rows wide. Never a rejected
/// span's entries, matching
/// ``TerminalWrappedPathResolution/nativeMatchKeys``'s same winning-only
/// rule.
///
/// A caller materializes these into absolute viewport ranges by adding the
/// clicked row's own viewport row to `rowOffsetFromClicked` — this type
/// intentionally carries no absolute row itself, since that would require
/// re-deriving it correctly at every call site instead of once.
/// design-next-round-bundle-8810.md §1 — whether (B) ExternalHover's cell
/// columns for a resolved candidate could be computed at all. A non-ASCII
/// adjacent row makes `column` a terminal-cell index that no longer lines
/// up with `String` character indices (the same reason every ASCII guard
/// in `String+TerminalPathTokens.swift` exists), so a candidate resolved
/// through that row's fragment TEXT alone (``String/trailingContinuationFragmentText()``,
/// the click-only fallback) has real path/match-key data but no column
/// range to underline. This type makes that "unknown," not "wrong" or
/// "silently absent": a caller must not guess a column range, and must not
/// treat this the same as `.available([])` (which means "no spans, e.g. a
/// resolution constructed directly rather than through the wrap-resolver
/// paths" — a different, always-safe-to-ignore case).
///
/// (B) ExternalHover fails closed on `.unavailableNonASCIIRow` — no
/// candidate is shown, rather than one with a wrong or missing underline —
/// while click still opens the resolved path (its correctness never
/// depended on columns at all).
public enum TerminalWrappedCellSpans: Sendable, Equatable {
    case available([TerminalWrappedPathCellSpan])
    /// The resolution joined through at least one non-ASCII row via
    /// text-only extraction — see this type's own doc.
    case unavailableNonASCIIRow
}

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
    /// Ordered, deduplicated exact-match keys for correlating this
    /// candidate against a native Ghostty `open_url` callback for the same
    /// click.
    ///
    /// Through the 2-row `resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)`
    /// overload, at most 3:
    ///
    /// 1. The raw, fully joined candidate text (clicked token and adjacent
    ///    fragment concatenated in the order used to build ``path``).
    /// 2. The clicked row's raw fragment (the token alone).
    /// 3. The winning direction's adjacent row's raw fragment alone.
    ///
    /// Through the geometry-aware `resolveWrappedCandidate(seed:window:cwd:geometry:)`
    /// overload, at most 8 (final-spec-scope-expansion-8810.md §6): every
    /// clicked-row-containing contiguous subchain of the winning span, plus
    /// the clicked row's immediate neighbors, in that stable order — which
    /// degenerates to the exact 3-key set/order above when the winning
    /// span happens to be 2 rows wide.
    ///
    /// Only the *winning* span/direction's constituents are ever included —
    /// never a rejected one's fragment, which would widen the set of
    /// native text this candidate can claim beyond what this click actually
    /// resolved. Empty entries are dropped and duplicates collapsed, so the
    /// array can have fewer entries than the cap.
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
    /// re-tokenizing. `.available` with exactly 2 entries when resolved
    /// through
    /// ``TerminalPathResolver/resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``
    /// via the guarded, column-range extractors; `.available([])` for a
    /// `TerminalWrappedPathResolution` constructed directly (e.g. in
    /// existing click-arbitrator tests that only need `path`/
    /// `nativeMatchKeys`); `.unavailableNonASCIIRow` when the resolution
    /// instead joined through ``String/trailingContinuationFragmentText()``'s
    /// text-only, click-only fallback (design-next-round-bundle-8810.md
    /// §1) — see ``TerminalWrappedCellSpans``'s own doc for what a caller
    /// must do with that case.
    public let cellSpans: TerminalWrappedCellSpans

    public init(
        path: String,
        nativeMatchKeys: [String],
        cellSpans: TerminalWrappedCellSpans = .available([])
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
    ///   - columns: The physical grid's column count, when known —
    ///     final-spec-scope-expansion-8810.md §3.2's third row-local
    ///     disposition (``TerminalRowLocalDisposition/rowLocalHitAwaitingMirrorSlashSeam``)
    ///     needs this to detect whether the clicked token reaches the
    ///     row's strict physical right edge, which a caller with no
    ///     window/geometry at hand (the legacy 2-row callers) simply
    ///     can't supply — `nil` here can NEVER reach that disposition,
    ///     only ``TerminalRowLocalDisposition/noRowLocalHit`` or
    ///     ``TerminalRowLocalDisposition/explicitTrailingSlashSeamBypass``,
    ///     exactly matching this method's pre-§3.2 behavior byte-for-byte.
    /// - Returns: A seed naming which adjacent row would complete the
    ///   token, or `nil` when no wrapped-path candidate touches `column`.
    /// review-slash-boundary-and-codex-comparison.md §2's row1/leading-side
    /// fix (issue #8810 bug A): a row-local hit no longer unconditionally
    /// wins. Token/range extraction now runs BEFORE the row-local check, and
    /// row-local resolving still returns `nil` here in every case EXCEPT two
    /// narrow exceptions — see ``TerminalRowLocalDisposition``'s own doc for
    /// each case, and final-spec §3 generally.
    ///
    /// The FIRST exception (bug A, ``TerminalRowLocalDisposition/explicitTrailingSlashSeamBypass``)
    /// requires: the match has a `.next` direction (which, by
    /// ``String/wrapContinuationToken(atColumn:maxIndentation:)``'s own
    /// construction, already implies the token touches the row's trailing
    /// boundary — condition 3 in the design doc is structurally guaranteed
    /// by condition 1, not checked separately), and the clicked token
    /// itself ends with `/`.
    ///
    /// The SECOND exception (final-spec §3.2,
    /// ``TerminalRowLocalDisposition/rowLocalHitAwaitingMirrorSlashSeam``)
    /// requires `columns` to be supplied AND the clicked token to reach
    /// the row's strict physical right edge — final-spec §1's adopted
    /// `fullnessTolerance = 0` policy, matching
    /// ``TerminalWrapGeometry``'s own default; there is no lower row
    /// available at seed-construction time to route this through
    /// ``WrapBoundaryOracle`` the way the evaluator's OWN boundary checks
    /// do, so this uses ``String/lastNonWhitespaceColumn`` directly with
    /// that same tolerance-0 semantics spelled out inline instead.
    ///
    /// EITHER exception only produces a PROVISIONAL seed: the actual
    /// decision still requires further confirmation downstream (bug A:
    /// ``resolveSingleDirection(_:seed:adjacentRow:cwd:)``'s matching
    /// `explicitSlashSeam` bypass; §3.2: `evaluateContiguousSpans`'s own
    /// mirror-seam-only gating on this disposition). If that later
    /// confirmation fails, `resolveWrappedCandidate` returns `nil` exactly
    /// as if this method had returned `nil` directly, so a caller's
    /// existing row-local fallback (triggered by a `nil` candidate, not
    /// by a `nil` seed specifically) still applies identically either
    /// way — final-spec §3.2 rule 4.
    public func wrappedPathSeed(
        in clickedRow: String,
        column: Int,
        cwd: String,
        columns: Int? = nil
    ) -> TerminalWrappedPathSeed? {
        guard let match = clickedRow.wrapContinuationToken(
            atColumn: column,
            maxIndentation: Self.maxContinuationIndentation
        ), match.token.count <= Self.maxWrappedFragmentLength else {
            return nil
        }

        let disposition: TerminalRowLocalDisposition
        if resolveVisibleLinePath(clickedRow, column: column, cwd: cwd) != nil {
            if match.directions.contains(.next), match.token.hasSuffix("/") {
                disposition = .explicitTrailingSlashSeamBypass
            } else if let columns,
                      let lastColumn = clickedRow.lastNonWhitespaceColumn,
                      lastColumn >= columns - 1 {
                disposition = .rowLocalHitAwaitingMirrorSlashSeam
            } else {
                return nil
            }
        } else {
            disposition = .noRowLocalHit
        }

        return TerminalWrappedPathSeed(
            directions: match.directions,
            token: match.token,
            tokenStartColumn: match.startColumn,
            tokenEndColumn: match.endColumn,
            disposition: disposition
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
        evaluateWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd).candidate
    }

    /// final-spec-scope-expansion-8810.md §2/§4-§10 — the geometry-aware,
    /// multi-row entry point. Unlike
    /// ``resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``, this
    /// takes a whole ``TerminalPhysicalRowWindow`` (not just the two rows
    /// immediately adjacent to the clicked one) — the contiguous-span
    /// evaluator needs to see every row a candidate might span (up to
    /// ``maxWrappedRows``), which a single `previousRow`/`nextRow` pair
    /// structurally cannot carry.
    ///
    /// final-spec §10's compatibility contract: `geometry: nil` falls
    /// back to the EXACT adjacent-row-only behavior of
    /// ``resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)`` (sourcing
    /// `previousRow`/`nextRow` from the window's immediate neighbors) —
    /// never the multi-row evaluator. A non-`nil` geometry activates the
    /// contiguous-span evaluator (final-spec §4), the mirror-slash-seam
    /// boundary predicate (§5), and the cap-8 `nativeMatchKeys` ordering
    /// (§6).
    ///
    /// - Parameters:
    ///   - seed: The seed returned by ``wrappedPathSeed(in:column:cwd:)``,
    ///     tokenized from `window.rows[window.clickedIndex]`.
    ///   - window: The physical rows around the click, with `window`
    ///     being the sole owner of the grid's column count.
    ///   - cwd: The surface's working directory.
    ///   - geometry: The fullness-guard tunable; `nil` for legacy
    ///     adjacent-row-only behavior.
    /// - Returns: The resolved candidate when exactly one contiguous span
    ///   dominates every other successful span; `nil` when zero spans
    ///   succeed, or when multiple succeed without one containing all the
    ///   others (final-spec §4.3).
    public func resolveWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        window: TerminalPhysicalRowWindow,
        cwd: String,
        geometry: TerminalWrapGeometry?
    ) -> TerminalWrappedPathResolution? {
        guard let geometry else {
            let previousRow = window.clickedIndex > 0 ? window.rows[window.clickedIndex - 1] : nil
            let nextRow = window.clickedIndex + 1 < window.rows.count ? window.rows[window.clickedIndex + 1] : nil
            return resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd)
        }
        // final-spec §2.2: `tolerance >= columns` is checked here, the one
        // place both a window (with `columns`) and a geometry are
        // available together.
        guard geometry.fullnessTolerance < window.columns else { return nil }
        return evaluateContiguousSpans(seed: seed, window: window, cwd: cwd, geometry: geometry).candidate
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
        evaluateWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd).outcomes
    }

    /// impl-bugB-diagnostics-v2 (review-bugB-bare-token-no-slash.md §4's
    /// closing note) — runs the per-direction resolution exactly ONCE,
    /// returning both the collapsed single-candidate result (mirroring
    /// ``resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)``) and the
    /// full per-direction outcome map (mirroring
    /// ``diagnoseWrappedCandidate(seed:previousRow:nextRow:cwd:)``) from
    /// that SAME evaluation. Both of those public methods now delegate to
    /// this internally, so calling either alone still costs exactly the
    /// documented per-direction filesystem-probe budget; a caller that
    /// needs BOTH pieces (e.g. an abort-path DEBUG log) should call this
    /// directly instead of calling both public methods separately, which
    /// would otherwise re-run the same probes twice for one click/hover.
    public func evaluateWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        previousRow: String?,
        nextRow: String?,
        cwd: String
    ) -> (candidate: TerminalWrappedPathResolution?, outcomes: [TerminalWrapDirection: TerminalWrappedCandidateDirectionOutcome]) {
        // final-spec §3.2 rule 2 — a seed in this disposition may ONLY
        // produce a candidate through a boundary that satisfies
        // `mirrorSlashSeam`, which needs `columns` (a window's, never
        // just two bare row strings) to evaluate at all. This 2-row
        // legacy path structurally has no `columns`, so it can never
        // satisfy rule 2 — it must always defer to the existing
        // row-local path (rule 4), never attempt the ordinary
        // per-direction join `resolveSingleDirection` would otherwise
        // run. Only the geometry-aware `resolveWrappedCandidate(seed:window:cwd:geometry:)`
        // overload can actually resolve this disposition.
        guard seed.disposition != .rowLocalHitAwaitingMirrorSlashSeam else {
            return (nil, [:])
        }

        var outcomes: [TerminalWrapDirection: TerminalWrappedCandidateDirectionOutcome] = [:]

        if seed.directions.contains(.previous), let previousRow {
            outcomes[.previous] = resolveSingleDirection(.previous, seed: seed, adjacentRow: previousRow, cwd: cwd)
        }
        if seed.directions.contains(.next), let nextRow {
            outcomes[.next] = resolveSingleDirection(.next, seed: seed, adjacentRow: nextRow, cwd: cwd)
        }

        let successes = outcomes.values.compactMap { outcome -> TerminalWrappedPathResolution? in
            if case .succeeded(let resolution) = outcome { return resolution }
            return nil
        }
        return (successes.count == 1 ? successes[0] : nil, outcomes)
    }

    /// impl-bugB-diagnostics-v2 (review-bugB-bare-token-no-slash.md §4) —
    /// the shape-only diagnostic for a `noCandidate` abort: cell row/
    /// column, the stable snapshot's `gridColumns`, the seed token's
    /// shape, and — per named direction — the REAL outcome plus shape
    /// flags computed by continuing past whichever guard would have
    /// stopped `resolveSingleDirection` first (never changing what it
    /// actually decides; this is diagnosis only). Never returns or logs
    /// raw row/token/fragment text.
    ///
    /// This is its OWN single pass, independent of
    /// ``evaluateWrappedCandidate(seed:previousRow:nextRow:cwd:)`` — the
    /// two compute different things (a go/no-go decision that stops at
    /// the first failing guard, vs. every flag regardless of which guard
    /// would have stopped first) and so cannot share one evaluation the
    /// way ``resolveWrappedCandidate``/``diagnoseWrappedCandidate`` can.
    /// It stays within the same bounded per-direction probe budget
    /// (`resolveSingleDirection`'s own two probes) as the real
    /// resolution — this diagnostic is only ever reached on an
    /// already-failed abort path, never a hot path.
    public func diagnoseCandidateShape(
        seed: TerminalWrappedPathSeed,
        previousRow: String?,
        nextRow: String?,
        cwd: String,
        cellRow: Int,
        cellColumn: Int,
        gridColumns: Int
    ) -> TerminalWrappedCandidateShapeDiagnostic {
        var directions: [TerminalWrapDirection: TerminalWrappedDirectionShapeDiagnostic] = [:]
        if seed.directions.contains(.previous), let previousRow {
            directions[.previous] = diagnoseSingleDirectionShape(.previous, seed: seed, adjacentRow: previousRow, cwd: cwd)
        }
        if seed.directions.contains(.next), let nextRow {
            directions[.next] = diagnoseSingleDirectionShape(.next, seed: seed, adjacentRow: nextRow, cwd: cwd)
        }
        return TerminalWrappedCandidateShapeDiagnostic(
            cellRow: cellRow,
            cellColumn: cellColumn,
            gridColumns: gridColumns,
            tokenShape: TerminalWrappedTokenShape(
                text: seed.token,
                startColumn: seed.tokenStartColumn,
                endColumn: seed.tokenEndColumn
            ),
            directions: directions
        )
    }

    private func diagnoseSingleDirectionShape(
        _ direction: TerminalWrapDirection,
        seed: TerminalWrappedPathSeed,
        adjacentRow: String,
        cwd: String
    ) -> TerminalWrappedDirectionShapeDiagnostic {
        let outcome = resolveSingleDirection(direction, seed: seed, adjacentRow: adjacentRow, cwd: cwd)

        let fragmentMatch: (fragment: String, startColumn: Int, endColumn: Int)?
        switch direction {
        case .next:
            fragmentMatch = adjacentRow.leadingContinuationFragmentWithRange(maxIndentation: Self.maxContinuationIndentation)
        case .previous:
            fragmentMatch = adjacentRow.trailingContinuationFragmentWithRange()
        }
        guard let fragmentMatch else {
            return TerminalWrappedDirectionShapeDiagnostic(
                outcome: outcome,
                fragmentShape: nil,
                leadingPieceIsPathPrefixShaped: nil,
                candidateIsPathShaped: nil,
                fragmentAloneExists: nil,
                candidateExists: nil
            )
        }
        let fragment = fragmentMatch.fragment
        let fragmentShape = TerminalWrappedTokenShape(
            text: fragment,
            startColumn: fragmentMatch.startColumn,
            endColumn: fragmentMatch.endColumn
        )

        let leadingPiece = direction == .next ? seed.token : fragment
        let leadingPieceIsPathPrefixShaped = leadingPiece.isWrappedPathPrefixShaped

        // Diagnostic-only continuation past the guards `resolveSingleDirection`
        // itself would have stopped at (length caps, prefix shape,
        // fragment-alone existence) — bounded to the SAME two probes
        // (fragment alone, joined candidate) that call already budgets
        // for, never more.
        let fragmentAloneExists = probeExists(fragment, cwd: cwd) != nil

        let candidateRaw: String
        switch direction {
        case .next: candidateRaw = seed.token + fragment
        case .previous: candidateRaw = fragment + seed.token
        }
        let candidateIsPathShaped = candidateRaw.isWrappedPathCandidateShaped
        let candidateExists = candidateIsPathShaped && probeExists(candidateRaw, cwd: cwd) != nil

        return TerminalWrappedDirectionShapeDiagnostic(
            outcome: outcome,
            fragmentShape: fragmentShape,
            leadingPieceIsPathPrefixShaped: leadingPieceIsPathPrefixShaped,
            candidateIsPathShaped: candidateIsPathShaped,
            fragmentAloneExists: fragmentAloneExists,
            candidateExists: candidateExists
        )
    }

    private func resolveSingleDirection(
        _ direction: TerminalWrapDirection,
        seed: TerminalWrappedPathSeed,
        adjacentRow: String,
        cwd: String
    ) -> TerminalWrappedCandidateDirectionOutcome {
        let token = seed.token
        // design-next-round-bundle-8810.md §1 — `.next` always uses the
        // guarded, column-ranged extractor (the clicked column is the
        // only place columns matter for THIS row's own token, but
        // `.next`'s fragment sits on the row the clicked column never
        // touches — still guarded, unrelaxed). `.previous` prefers that
        // same guarded extractor too — (B) ExternalHover's underline
        // needs its column range — but falls back to
        // ``String/trailingContinuationFragmentText()`` when the guarded
        // extractor fails ONLY because `adjacentRow` is non-ASCII: the
        // trailing fragment's TEXT never depended on any column
        // projection at all, unlike the guard's actual reason to exist.
        // `fragmentColumns == nil` after this means the fallback was
        // taken, and the eventual `.succeeded` result reports
        // `.unavailableNonASCIIRow` instead of guessing a column range.
        //
        // This fallback is reachable ONLY through this 2-row legacy
        // path: `evaluateContiguousSpans` (the geometry-aware, multi-row
        // evaluator) never calls `resolveSingleDirection` at all — it
        // extracts its own pieces directly, always through the guarded
        // extractors — so a `geometry` value in play always means the
        // guarded extractor and nothing else, matching that design's
        // rule 2 ("geometry が渡されている場合は text-only 経路を使わない").
        let fragment: String
        let fragmentColumns: (startColumn: Int, endColumn: Int)?
        switch direction {
        case .next:
            guard let match = adjacentRow.leadingContinuationFragmentWithRange(
                maxIndentation: Self.maxContinuationIndentation
            ) else { return .noFragment }
            fragment = match.fragment
            fragmentColumns = (match.startColumn, match.endColumn)
        case .previous:
            if let match = adjacentRow.trailingContinuationFragmentWithRange() {
                fragment = match.fragment
                fragmentColumns = (match.startColumn, match.endColumn)
            } else if let textOnly = adjacentRow.trailingContinuationFragmentText() {
                fragment = textOnly
                fragmentColumns = nil
            } else {
                return .noFragment
            }
        }
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
            // `.next`'s `fragmentColumns` is always populated (guarded
            // extraction is the only branch above for that direction).
            explicitSlashSeam = token.hasSuffix("/") && fragmentColumns?.startColumn == 0
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
        // `fragmentColumns == nil` (the text-only fallback was taken)
        // means there is no real column range to report at all — never
        // guessed, never silently dropped to `.available([])` (which
        // would read as "this resolution legitimately has no spans," a
        // different case) — see ``TerminalWrappedCellSpans``'s own doc.
        let cellSpans: TerminalWrappedCellSpans
        if let fragmentColumns {
            cellSpans = .available([
                TerminalWrappedPathCellSpan(
                    rowOffsetFromClicked: 0,
                    startColumn: seed.tokenStartColumn,
                    endColumn: seed.tokenEndColumn
                ),
                TerminalWrappedPathCellSpan(
                    rowOffsetFromClicked: direction == .previous ? -1 : 1,
                    startColumn: fragmentColumns.startColumn,
                    endColumn: fragmentColumns.endColumn
                ),
            ])
        } else {
            cellSpans = .unavailableNonASCIIRow
        }
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

    // MARK: - final-spec-scope-expansion-8810.md §4-§8 — contiguous-span evaluator

    /// Maximum physical rows a single wrapped-path candidate may span.
    /// final-spec §7: the search's primary guard is fullness (every
    /// internal boundary must reach the strict right edge); this is a
    /// runaway backstop, not the main defense.
    private static let maxWrappedRows = 4
    /// Maximum joined-candidate length, in UTF-8 BYTES (never `Character`
    /// or terminal-cell count — final-spec §7 is explicit that those units
    /// must not be conflated here).
    private static let maxWrappedCandidateBytes = 2048

    /// One row's contribution to a multi-row span, plus the column range
    /// it occupies on that physical row (for `cellSpans`).
    private struct SpanPiece {
        let text: String
        let startColumn: Int
        let endColumn: Int
    }

    /// A structurally- and existence-guarded span that resolved to a real
    /// path — a candidate for adoption (final-spec §4.3), not yet the
    /// final answer.
    private struct SpanSuccess {
        let range: ClosedRange<Int>
        let standardizedPath: String
        let pieces: [SpanPiece]
    }

    /// design-next-round-bundle-8810.md §3 — the single seam behind every
    /// "does this boundary look like a hard-wrap continuation" judgment
    /// the contiguous-span evaluator makes: final-spec §4.2's per-boundary
    /// fullness guard, and ``mirrorSlashSeam(_:_:)``'s own upper-row-full
    /// sub-check (§5.1) — never two separate copies of the same fact.
    /// ``TextHeuristicWrapBoundaryOracle`` (strict physical edge, a
    /// configurable tolerance) is the only implementation today; a future
    /// pass can inject one that instead consumes Ghostty's native
    /// `hardWrapBoundary` verdict (which has access to `row.wrap`/actual
    /// cell data this text-only heuristic can only approximate) without
    /// touching a single line of the span enumeration logic below —
    /// exactly the reason this seam exists (design's own "同じ事実の
    /// 二重の正本を作らない" rationale).
    private protocol WrapBoundaryOracle {
        /// - Parameters:
        ///   - upperRow: The physical row immediately above the boundary.
        ///   - lowerRow: The physical row immediately below the boundary
        ///     — carried for a future native implementation that may
        ///     need it; the current text heuristic only ever inspects
        ///     `upperRow`.
        ///   - columns: The physical grid's column count.
        func isWrapContinuationBoundary(upperRow: String, lowerRow: String, columns: Int) -> Bool
    }

    /// The current, only ``WrapBoundaryOracle`` implementation: strict
    /// physical right edge, with a configurable tolerance
    /// (final-spec-scope-expansion-8810.md §1/§2.2) — byte-for-byte the
    /// same judgment `evaluateContiguousSpans` made inline before this
    /// seam existed.
    private struct TextHeuristicWrapBoundaryOracle: WrapBoundaryOracle {
        let fullnessTolerance: Int

        func isWrapContinuationBoundary(upperRow: String, lowerRow: String, columns: Int) -> Bool {
            guard let lastColumn = upperRow.lastNonWhitespaceColumn else { return false }
            return lastColumn >= columns - 1 - fullnessTolerance
        }
    }

    /// final-spec §4 — enumerates every structurally-eligible contiguous
    /// row span (length 2...``maxWrappedRows``) containing
    /// `window.clickedIndex`, evaluates each independently, and adopts the
    /// unique dominating success (§4.3). `geometry` is always non-`nil`
    /// here — the `nil` fallback is handled by the caller before this is
    /// ever reached.
    private func evaluateContiguousSpans(
        seed: TerminalWrappedPathSeed,
        window: TerminalPhysicalRowWindow,
        cwd: String,
        geometry: TerminalWrapGeometry
    ) -> (candidate: TerminalWrappedPathResolution?, spanCount: Int) {
        let clickedIndex = window.clickedIndex
        let oracle: any WrapBoundaryOracle = TextHeuristicWrapBoundaryOracle(fullnessTolerance: geometry.fullnessTolerance)
        var probeBudget = TerminalWrapProbeBudget()
        // final-spec §8 rule 2: the SAME raw fragment/candidate probed by
        // more than one span (e.g. the same `spanStart` fragment reused
        // across several `spanEnd` choices) is only ever probed once.
        var probeCache: [String: String?] = [:]

        func probe(_ raw: String) -> String? {
            if let cached = probeCache[raw] { return cached }
            guard probeBudget.consume() else { return nil }
            let result = probeExists(raw, cwd: cwd)
            probeCache[raw] = result
            return result
        }

        // final-spec §5.1: pure, boundary-local — never a property of
        // which row was clicked (see that section's own "クリック行の属性に
        // してはいけません" note, which is exactly why this takes two rows
        // and never the seed/clicked index).
        func mirrorSlashSeam(upperRow: String, lowerRow: String) -> Bool {
            guard oracle.isWrapContinuationBoundary(upperRow: upperRow, lowerRow: lowerRow, columns: window.columns) else {
                return false
            }
            return lowerRow.first == "/"
        }

        // final-spec §4.1: the clicked row always contributes `seed.token`
        // (regardless of whether it also happens to be a span endpoint);
        // an endpoint that ISN'T the clicked row contributes its
        // trailing/leading fragment (mirroring the existing 2-row
        // `.previous`/`.next` extraction); every other row contributes its
        // whole grid-padding-trimmed content.
        func piece(at row: Int, spanStart: Int, spanEnd: Int) -> SpanPiece? {
            if row == clickedIndex {
                return SpanPiece(text: seed.token, startColumn: seed.tokenStartColumn, endColumn: seed.tokenEndColumn)
            }
            if row == spanStart {
                guard let match = window.rows[row].trailingContinuationFragmentWithRange() else { return nil }
                return SpanPiece(text: match.fragment, startColumn: match.startColumn, endColumn: match.endColumn)
            }
            if row == spanEnd {
                guard let match = window.rows[row].leadingContinuationFragmentWithRange(
                    maxIndentation: Self.maxContinuationIndentation
                ) else { return nil }
                return SpanPiece(text: match.fragment, startColumn: match.startColumn, endColumn: match.endColumn)
            }
            guard let match = window.rows[row].gridPaddingTrimmedWithRange(), match.startColumn == 0 else {
                // A middle row (fully enclosed by the span on both sides)
                // that's still INDENTED is exactly the "independent list
                // item after a directory line" shape final-spec §3.1 and
                // Ghostty's own `link_wrap.zig` `startsIndependentLink`
                // fail-close on for the 2-row case — an indented row is
                // ambiguous with an unrelated sibling line, not proof of
                // continuation, regardless of how full its neighbors are.
                return nil
            }
            return SpanPiece(text: match.fragment, startColumn: match.startColumn, endColumn: match.endColumn)
        }

        // final-spec §3.2 rules 1-4 — a seed in this disposition may
        // NEVER extend upward (rule 3: only "下流行" — downstream rows —
        // may be added once the mirror boundary holds) and may ONLY
        // produce a candidate at all when the boundary immediately after
        // the clicked row satisfies `mirrorSlashSeam` (rule 2). Checked
        // ONCE here, not per-span inside the loop below, since it's a
        // fixed fact about this boundary, independent of `spanEnd`; if
        // it doesn't hold, rule 4 applies — no wrapped candidate, the
        // caller's existing row-local path is unaffected.
        if seed.disposition == .rowLocalHitAwaitingMirrorSlashSeam {
            guard clickedIndex + 1 < window.rows.count,
                  mirrorSlashSeam(upperRow: window.rows[clickedIndex], lowerRow: window.rows[clickedIndex + 1]) else {
                return (nil, 0)
            }
        }

        let minStart = seed.disposition == .rowLocalHitAwaitingMirrorSlashSeam
            ? clickedIndex
            : max(0, clickedIndex - (Self.maxWrappedRows - 1))
        let maxEnd = min(window.rows.count - 1, clickedIndex + (Self.maxWrappedRows - 1))

        var successes: [SpanSuccess] = []
        for spanStart in minStart...clickedIndex {
            // final-spec §5.3 — extending a span upward when the
            // tokenizer didn't license `.previous` for the clicked token
            // (the literal-`/`-continuation case it deliberately keeps
            // `.next`-only) is eligible ONLY through the mirror-seam
            // exception at the SINGLE boundary immediately above the
            // clicked row, and never propagates further: this is that
            // row's own narrow exception (final-spec §3.3's row1-click
            // scenario is its sole justification), not a general
            // upward-search license the seed's own `directions` didn't
            // grant. Without this, an absolute-prefixed token could
            // spuriously reach two-or-more rows upward through nothing
            // but incidental fullness on an intermediate boundary — the
            // exact coincidental-override shape final-spec §4.4 warns is
            // never fully excludable, so this narrows it as tightly as
            // the one documented scenario requires.
            if spanStart < clickedIndex, !seed.directions.contains(.previous) {
                guard spanStart == clickedIndex - 1,
                      mirrorSlashSeam(upperRow: window.rows[clickedIndex - 1], lowerRow: window.rows[clickedIndex])
                else { continue }
            }
            for spanEnd in clickedIndex...maxEnd {
                if spanEnd > clickedIndex {
                    guard seed.directions.contains(.next) else { continue }
                }
                let length = spanEnd - spanStart + 1
                guard length >= 2, length <= Self.maxWrappedRows else { continue }

                // final-spec §4.2 — fullness on every internal boundary.
                var fullnessOK = true
                for boundary in spanStart..<spanEnd {
                    guard oracle.isWrapContinuationBoundary(
                        upperRow: window.rows[boundary], lowerRow: window.rows[boundary + 1], columns: window.columns
                    ) else {
                        fullnessOK = false
                        break
                    }
                }
                guard fullnessOK else { continue }

                var pieces: [SpanPiece] = []
                var extractionOK = true
                for row in spanStart...spanEnd {
                    guard let piece = piece(at: row, spanStart: spanStart, spanEnd: spanEnd),
                          piece.text.count <= Self.maxWrappedFragmentLength else {
                        extractionOK = false
                        break
                    }
                    pieces.append(piece)
                }
                guard extractionOK, let leadingPiece = pieces.first, let trailingPiece = pieces.last else { continue }

                // final-spec §5.1/§5.3 — mirror seam is per-boundary, not
                // per-span; only the boundary immediately after the
                // leading piece / immediately before the trailing piece
                // is relevant to THAT piece's own guard bypass.
                let leadingBoundaryHasMirrorSeam = spanStart < spanEnd &&
                    mirrorSlashSeam(upperRow: window.rows[spanStart], lowerRow: window.rows[spanStart + 1])
                let trailingBoundaryHasMirrorSeam = spanEnd > spanStart &&
                    mirrorSlashSeam(upperRow: window.rows[spanEnd - 1], lowerRow: window.rows[spanEnd])

                // The pre-existing bug A `explicitSlashSeam` bypass
                // (`resolveSingleDirection`'s own, predating final-spec),
                // generalized boundary-locally exactly like mirror seam
                // above: a piece ending with `/` is itself strong-enough
                // join evidence to bypass fragment-alone-exists at THAT
                // boundary, provided the row immediately across it is
                // unindented (`.startColumn == 0`). Bug A's 10 existing
                // 2-row fixtures rely on this; without it here, their
                // geometry-aware/legacy parity (final-spec §10) would
                // break for exactly the fixtures that established it.
                let leadingBoundaryHasLegacySlashSeam = spanStart < spanEnd &&
                    leadingPiece.text.hasSuffix("/") && pieces[1].startColumn == 0
                let trailingBoundaryHasLegacySlashSeam = spanEnd > spanStart &&
                    pieces[pieces.count - 2].text.hasSuffix("/") && trailingPiece.startColumn == 0

                // final-spec §4.2 — outer endpoint guard: leading piece
                // must be path-prefix-shaped, unless a boundary bypass
                // applies (a piece ending with `/` already contains `/`
                // and would pass this trivially anyway, so this bypass
                // only ever matters for `fragmentAloneExists` below).
                //
                // design-next-round-bundle-8810.md §2 (leading-piece
                // requirement, confirmed correct and intentional) — a span
                // whose leading piece (the first row's own fragment) isn't
                // path-prefix-shaped never succeeds, REGARDLESS of row
                // count: this is exactly what rejects a bare-relative
                // multi-row split that wraps INSIDE the path's first
                // segment (e.g. `verylongdirname` split as
                // `verylongd`/`irname/file.md`) — a deliberate fail-closed
                // against P0-2-style coincidental joins, not a gap. Only
                // ``explicitTrailingSlashSeamBypass`` and `mirrorSlashSeam`
                // bypass it, and each only under its own narrow condition
                // above — relaxing this would need PROVENANCE that two
                // rows are the same link (a terminal-provided semantic
                // range/hyperlink identity), never a filesystem heuristic
                // alone.
                guard leadingBoundaryHasMirrorSeam || leadingBoundaryHasLegacySlashSeam
                    || leadingPiece.text.isWrappedPathPrefixShaped else { continue }

                let candidateRaw = pieces.map(\.text).joined()
                guard candidateRaw.utf8.count <= Self.maxWrappedCandidateBytes else { continue }
                guard candidateRaw.isWrappedPathCandidateShaped else { continue }

                // final-spec §8 rule 3 — candidate existence is probed
                // BEFORE the endpoint fragment-alone probes, so a span
                // whose joined candidate doesn't exist never spends probes
                // on fragment-alone checks it can no longer affect.
                guard let standardizedPath = probe(candidateRaw) else { continue }

                // final-spec §4.2 — fragment-alone-exists applies only to
                // the two OUTER endpoints, and only when that endpoint
                // isn't the clicked row itself (§8 rule 1: never re-probe
                // the clicked token alone) — bypassed at a mirror-seam or
                // legacy-slash-seam boundary.
                if spanStart != clickedIndex, !leadingBoundaryHasMirrorSeam, !leadingBoundaryHasLegacySlashSeam,
                   probe(leadingPiece.text) != nil {
                    continue
                }
                if spanEnd != clickedIndex, !trailingBoundaryHasMirrorSeam, !trailingBoundaryHasLegacySlashSeam,
                   probe(trailingPiece.text) != nil {
                    continue
                }

                successes.append(SpanSuccess(range: spanStart...spanEnd, standardizedPath: standardizedPath, pieces: pieces))
            }
        }

        guard !successes.isEmpty else { return (nil, 0) }

        // final-spec §4.3 — the unique span containing every other
        // success's row range dominates; anything else (including zero
        // such spans, i.e. genuinely incomparable successes) fails closed.
        let dominating = successes.filter { candidate in
            successes.allSatisfy { other in
                other.range.lowerBound >= candidate.range.lowerBound && other.range.upperBound <= candidate.range.upperBound
            }
        }
        guard dominating.count == 1, let winner = dominating.first else { return (nil, successes.count) }

        // Clicked row's own span first, then the rest in ascending row
        // order — matches the existing 2-row overload's documented
        // "clicked token, then adjacent fragment" convention exactly (its
        // `cellSpans` doc: "clicked-first matches this type's own
        // narrative elsewhere"), so a multi-row candidate that happens to
        // degenerate to 2 rows produces byte-for-byte the same order.
        let orderedOffsets = [clickedIndex] + winner.range.filter { $0 != clickedIndex }
        let cellSpans = orderedOffsets.map { row -> TerminalWrappedPathCellSpan in
            let piece = winner.pieces[row - winner.range.lowerBound]
            return TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: row - clickedIndex,
                startColumn: piece.startColumn,
                endColumn: piece.endColumn
            )
        }
        let keys = nativeMatchKeys(range: winner.range, pieces: winner.pieces.map(\.text), clickedIndex: clickedIndex)
        return (
            TerminalWrappedPathResolution(
                path: winner.standardizedPath, nativeMatchKeys: keys, cellSpans: .available(cellSpans)
            ),
            successes.count
        )
    }

    /// final-spec §6 — the winning span's `nativeMatchKeys`: every
    /// clicked-row-containing contiguous subchain of `[i...j]`, plus the
    /// clicked row's immediate neighbors, in the exact stable order §6.2
    /// specifies, normalized/deduplicated/capped at 8.
    private func nativeMatchKeys(range: ClosedRange<Int>, pieces: [String], clickedIndex: Int) -> [String] {
        let i = range.lowerBound
        let j = range.upperBound
        let c = clickedIndex

        func joined(_ a: Int, _ b: Int) -> String {
            pieces[(a - i)...(b - i)].joined()
        }

        var ordered: [(Int, Int)] = [(i, j), (c, c)]
        if c - 1 >= i { ordered.append((c - 1, c - 1)) }
        if c + 1 <= j { ordered.append((c + 1, c + 1)) }

        // §6.1 rule 1's full set, minus what's already ordered above,
        // sorted by length descending then start index ascending (§6.2
        // rule 5).
        var remaining: [(Int, Int)] = []
        for a in i...c {
            for b in c...j {
                remaining.append((a, b))
            }
        }
        let alreadyOrdered = Set(ordered.map { "\($0.0)_\($0.1)" })
        remaining = remaining.filter { !alreadyOrdered.contains("\($0.0)_\($0.1)") }
        remaining.sort { lhs, rhs in
            let lhsLength = lhs.1 - lhs.0 + 1
            let rhsLength = rhs.1 - rhs.0 + 1
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return lhs.0 < rhs.0
        }
        ordered.append(contentsOf: remaining)

        var keys: [String] = []
        for (a, b) in ordered {
            let key = joined(a, b).normalizedTerminalWrapMatchKey()
            guard !key.isEmpty, !keys.contains(key) else { continue }
            keys.append(key)
            guard keys.count < 8 else { break }
        }
        return keys
    }
}

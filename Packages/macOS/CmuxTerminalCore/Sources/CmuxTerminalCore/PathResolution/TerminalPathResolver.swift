public import Foundation

/// A terminal row layout whose Swift `Character` offsets are proven to be
/// identical to terminal-cell columns.
///
/// This is a permanent seam for the proof, but the hand-coded implementation
/// is intentionally transient, like ``WrapBoundaryOracle``: once StringMap
/// slices (or another native cell-provenance API) are available, replace this
/// helper's implementation with that map and remove the hand-coded list. The
/// expected lifetime of this implementation is one release-sized slice, not
/// a second long-lived width model.
struct TerminalRowCellLayout: Sendable, Equatable {
    /// One measured narrow code point. Every entry records the exact Ghostty
    /// source revision, date, and method used for the measurement so an
    /// apparently harmless list expansion cannot silently become a width
    /// assumption.
    struct WidthMeasurement: Sendable, Equatable {
        let scalar: Unicode.Scalar
        let ghosttyCommit: String
        let measuredOn: String
        let method: String
    }

    /// The only non-ASCII scalars admitted by the current proof. An entry is
    /// eligible only when it is (a) one code point, (b) measured as
    /// `codepointWidth() == 1` by the same method in this Ghostty submodule,
    /// (c) not East Asian Width W/F, (d) not default Emoji_Presentation, and
    /// (e) accompanied by the per-entry measurement record below. Do not add
    /// an unmeasured character here.
    ///
    /// Measurement record: the parent-pinned Ghostty commit
    /// `abcf5697d4fcd05e29a83ccfc090d6e234952849`, measured on 2026-08-09 in a
    /// temporary checkout with `ghostty/src/unicode/main.zig`'s
    /// `codepointWidth()` exercised by the submodule's `zig build test`
    /// measurement harness.
    static let measuredNarrowScalarMetadata: [WidthMeasurement] = [
        WidthMeasurement(scalar: "\u{2022}", ghosttyCommit: "abcf5697d4fcd05e29a83ccfc090d6e234952849", measuredOn: "2026-08-09", method: "ghostty/src/unicode/main.zig codepointWidth() via zig build test"),
        WidthMeasurement(scalar: "\u{25CF}", ghosttyCommit: "abcf5697d4fcd05e29a83ccfc090d6e234952849", measuredOn: "2026-08-09", method: "ghostty/src/unicode/main.zig codepointWidth() via zig build test"),
        WidthMeasurement(scalar: "\u{25A0}", ghosttyCommit: "abcf5697d4fcd05e29a83ccfc090d6e234952849", measuredOn: "2026-08-09", method: "ghostty/src/unicode/main.zig codepointWidth() via zig build test"),
        WidthMeasurement(scalar: "\u{25CB}", ghosttyCommit: "abcf5697d4fcd05e29a83ccfc090d6e234952849", measuredOn: "2026-08-09", method: "ghostty/src/unicode/main.zig codepointWidth() via zig build test"),
        WidthMeasurement(scalar: "\u{2B24}", ghosttyCommit: "abcf5697d4fcd05e29a83ccfc090d6e234952849", measuredOn: "2026-08-09", method: "ghostty/src/unicode/main.zig codepointWidth() via zig build test"),
    ]

    private static let measuredNarrowScalars = Set(measuredNarrowScalarMetadata.map(\.scalar))

    private let characterCount: Int

    private init(characterCount: Int) {
        self.characterCount = characterCount
    }

    /// Returns a layout only when every `Character` is one scalar and that
    /// scalar is either printable ASCII (0x20...0x7E) or one of the measured
    /// narrow exceptions above. Printable ASCII is deliberately narrower than
    /// `isASCII`: tab is ASCII but is not a one-cell printable character.
    static func verified(for row: String) -> Self? {
        let characters = Array(row)
        guard characters.allSatisfy({ character in
            let scalars = Array(character.unicodeScalars)
            guard scalars.count == 1, let scalar = scalars.first else { return false }
            let isPrintableASCII = (0x20...0x7E).contains(scalar.value)
            return isPrintableASCII || measuredNarrowScalars.contains(scalar)
        }) else {
            return nil
        }
        return Self(characterCount: characters.count)
    }

    /// Converts an already-indexed Swift-character range to the corresponding
    /// cell range. The identity proof makes the conversion intentionally
    /// boring; bounds checking keeps callers from manufacturing an invalid
    /// span if token extraction changes.
    func cellRange(forCharacterOffsets range: Range<Int>) -> Range<Int>? {
        guard range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= characterCount else {
            return nil
        }
        return range
    }
}

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

/// design-decision-b1-fallback-policy.md rule 1 — the geometry-aware,
/// multi-row evaluator's outcome, structured so a caller can tell "judged
/// this candidate and rejected it" apart from "couldn't judge it at all"
/// instead of collapsing both to the same bare `nil` the way the public
/// ``TerminalPathResolver/resolveWrappedCandidate(seed:window:cwd:geometry:)``
/// overload still does, for source compatibility with every existing
/// caller that only ever wanted the collapsed optional. Only the shared,
/// multi-row entry point
/// (``TerminalPathResolver/resolveWrappedCandidate(seed:rows:clickedIndex:columns:cwd:purpose:)``)
/// inspects this directly, to decide whether its own narrow, click-only
/// text-only fallback may even be attempted.
public enum TerminalWrappedResolutionOutcome: Sendable, Equatable {
    case resolved(TerminalWrappedPathResolution)
    /// The evaluator judged at least one structurally-eligible span and
    /// said no (or rejected the click outright, e.g. a row-local
    /// disposition's own routing never reached a candidate). This is a
    /// DECISION — never grounds to fall back to a looser resolution path.
    case rejected(TerminalWrappedRejectionReason)
    /// No structurally-eligible span could be judged at all: a row the
    /// search needed is non-ASCII, so terminal-cell columns for it don't
    /// exist. design-decision-b1-fallback-policy.md rule 2's narrow
    /// conditions are the ONLY thing allowed to treat this as license to
    /// fall back to a text-only join instead of failing closed — and
    /// even then, that fallback re-derives its own eligibility rather
    /// than trusting this case alone (see
    /// ``TerminalPathResolver``'s `resolveTextOnlyPreviousFallback`).
    case notEvaluable(TerminalWrappedNotEvaluableReason)

    /// Stable, raw-text-free label for DEBUG diagnostics.
    public var diagnosticName: String {
        switch self {
        case .resolved: return "resolved"
        case .rejected(let reason): return reason.diagnosticName
        case .notEvaluable(let reason): return reason.diagnosticName
        }
    }
}

/// See ``TerminalWrappedResolutionOutcome/rejected(_:)``'s own doc — every
/// case here is "judged and said no," never "couldn't tell." Named after
/// the specific guard/decision that produced it, mirroring
/// ``TerminalWrappedCandidateDirectionOutcome``'s existing per-direction
/// vocabulary. **None of these are ever grounds for falling back to a
/// looser resolution path** (design-decision-b1-fallback-policy.md rule
/// 1's "rejected" bucket).
public enum TerminalWrappedRejectionReason: Sendable, Equatable {
    /// A boundary the span needed doesn't reach the strict physical right
    /// edge (final-spec §4.2) — the load-bearing guard B1 exists to
    /// protect.
    case fullnessGuardRejected
    /// More than one structurally-eligible span succeeded with none
    /// containing every other (final-spec §4.3) — genuinely ambiguous.
    case spanAmbiguous
    /// The joined, cwd-resolved candidate doesn't exist on disk.
    case candidateDoesNotExist
    /// An endpoint's own fragment already resolves to an existing path by
    /// itself, so joining it would be coincidental, not a continuation.
    case fragmentAloneExists
    /// The span's leading piece isn't itself shaped like a path prefix.
    case leadingPieceNotPathPrefixShaped
    /// The joined candidate isn't shaped like a real path.
    case candidateNotPathShaped
    /// final-spec §8's fixed probe budget was exhausted before this
    /// span's candidate could be checked.
    case probeBudgetExceeded
    /// The joined candidate exceeds the byte-length cap.
    case candidateTooLong
    /// The span would need more rows than `maxWrappedRows` allows.
    case rowCountExceeded
    /// A row-local hit's own mirror-seam or slash-seam routing
    /// (final-spec §3.2 and issue #8810's revised §3.1) never reached a
    /// candidate.
    case rowLocalPriorityBypass
    /// A row an eligible span needed had no extractable fragment/token at
    /// all (an ASCII row with nothing there to join) — distinct from
    /// every reason above.
    case fragmentNotExtractable

    /// Stable, raw-text-free label for DEBUG diagnostics.
    public var diagnosticName: String {
        switch self {
        case .fullnessGuardRejected: return "fullnessGuardRejected"
        case .spanAmbiguous: return "spanAmbiguous"
        case .candidateDoesNotExist: return "candidateDoesNotExist"
        case .fragmentAloneExists: return "fragmentAloneExists"
        case .leadingPieceNotPathPrefixShaped: return "leadingPieceNotPathPrefixShaped"
        case .candidateNotPathShaped: return "candidateNotPathShaped"
        case .probeBudgetExceeded: return "probeBudgetExceeded"
        case .candidateTooLong: return "candidateTooLong"
        case .rowCountExceeded: return "rowCountExceeded"
        case .rowLocalPriorityBypass: return "rowLocalPriorityBypass"
        case .fragmentNotExtractable: return "fragmentNotExtractable"
        }
    }
}

/// design-decision-b1-fallback-policy.md rule 1's "評価不能" bucket.
public enum TerminalWrappedNotEvaluableReason: Sendable, Equatable {
    /// A row the search needed is non-ASCII, so terminal-cell columns for
    /// it can't be computed at all — the same reason every ASCII guard in
    /// `String+TerminalPathTokens.swift` exists. No fullness, shape, or
    /// existence judgment could even be attempted for that row.
    case nonASCIIRowPreventsCellColumns

    /// Stable, raw-text-free label for DEBUG diagnostics.
    public var diagnosticName: String {
        switch self {
        case .nonASCIIRowPreventsCellColumns: return "nonASCIIRowPreventsCellColumns"
        }
    }
}

/// Which surface is asking the shared, multi-row resolution entry point
/// (``TerminalPathResolver/resolveWrappedCandidate(seed:rows:clickedIndex:columns:cwd:purpose:)``)
/// to resolve a candidate — design-decision-b1-fallback-policy.md rule 2
/// condition 2. `.hover` can never reach the conservative text-only fallback:
/// an automated, continuous underline built on an unverified column-less join
/// would be a silent false positive. A leading row may still serve hover when
/// ``TerminalRowCellLayout`` proves character-index == cell-column identity;
/// that branch has real ranges and is not a column-less join. `.click` may use
/// either branch once its own guards hold.
/// Threading this as an explicit, required parameter — rather than a
/// convention every caller has to remember — is what makes hover's
/// exclusion from that fallback something a reviewer (or a test) can
/// confirm by reading the call site, not by trusting it.
public enum TerminalWrappedResolutionPurpose: Sendable, Equatable {
    case click
    case hover
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
/// through that row's fragment TEXT alone (the conservative click-only
/// fallback) has real path/match-key data but no column range to underline.
/// This type makes that "unknown," not "wrong" or "silently absent": a
/// caller must not guess a column range, and must not treat this the same as
/// `.available([])` (which means "no spans, e.g. a resolution constructed
/// directly rather than through the wrap-resolver paths" — a different,
/// always-safe-to-ignore case). A verified leading-row layout is not this
/// case: its character-to-cell identity supplies exact ranges.
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
    /// instead joined through a conservative, text-only, click-only fallback
    /// (design-next-round-bundle-8810.md §1) — see
    /// ``TerminalWrappedCellSpans``'s own doc for what a caller must do with
    /// that case. A leading row accepted by the verified layout seam returns
    /// `.available` because its ranges are proven cell coordinates.
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
#if DEBUG
    /// Test-only events for proving that each resolver entry prepares one
    /// physical window and invokes the geometry evaluator once.
    enum DebugResolutionStep: Sendable {
        case windowPrepared
        case evaluatorInvoked
    }
#endif

    /// Maximum characters in a wrapped-path token or adjacent-row fragment.
    /// Mirrors POSIX `PATH_MAX` so a pathological row can't make
    /// tokenization unbounded.
    private static let maxWrappedFragmentLength = 1024
    /// Maximum leading ASCII spaces tolerated between a logical line's
    /// start and a wrapped-path fragment.
    private static let maxContinuationIndentation = 16

    private let fileExists: @Sendable (String) -> Bool
#if DEBUG
    private var debugResolutionObserver: (@Sendable (DebugResolutionStep) -> Void)?
#endif

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameter fileExists: The file-existence capability; defaults to the
    ///   real file system.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.fileExists = fileExists
#if DEBUG
        self.debugResolutionObserver = nil
#endif
    }

#if DEBUG
    /// Test-only observer; compiled out of Release builds.
    mutating func debugSetResolutionObserver(
        _ observer: (@Sendable (DebugResolutionStep) -> Void)?
    ) {
        debugResolutionObserver = observer
    }
#endif

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
    public func diagnoseSeedAbsence(in clickedRow: String, column: Int, cwd: String, columns: Int? = nil) -> String {
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
            let hasExplicitSlashSeam = match.directions.contains(.next) && match.token.hasSuffix("/")
            if !hasExplicitSlashSeam,
               let columns, columns > 0,
               let lastColumn = clickedRow.lastNonWhitespaceColumn,
               lastColumn < columns - 1 {
                let fullnessMargin = columns - 1 - lastColumn
                return "rowLocalHitMirrorSeamNotFull gridColumns=\(columns) clickedLastCol=\(lastColumn) fullnessMargin=\(fullnessMargin)"
            }
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
    ///
    /// design-decision-b1-fallback-policy.md rule 6 — `internal`, not
    /// `public`: this is the legacy, fullness-blind 2-row join, and its
    /// only sanctioned callers now are within this file — the geometry-
    /// aware overload's own `geometry: nil` compatibility branch, and
    /// `resolveTextOnlyPreviousFallback(seed:window:cwd:)`'s narrow,
    /// rule-2-gated use of it. No other module can reach it directly, so
    /// there is exactly one grep-auditable path into its behavior instead
    /// of an implicit fallback any geometry-aware caller could stumble
    /// into.
    func resolveWrappedCandidate(
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
        // design-decision-b1-fallback-policy.md rule 1 — this overload
        // keeps its pre-existing collapsed-optional contract for every
        // existing caller (`.rejected` and `.notEvaluable` both mean
        // "no candidate" here, same as before that distinction existed);
        // only the shared, multi-row entry point below inspects the
        // outcome itself to decide whether a narrow fallback even applies.
        switch evaluateContiguousSpans(seed: seed, window: window, cwd: cwd, geometry: geometry) {
        case .resolved(let resolution):
            return resolution
        case .rejected, .notEvaluable:
            return nil
        }
    }

    /// cmux-shared-behavior policy — the ONE resolution path both click
    /// (`GhosttyTerminalView.prepareCommandClickContext`) and hover
    /// (`ExternalHoverWorkService.resolveFully`) call once they already
    /// have a seed: the geometry-aware, multi-row evaluator
    /// (final-spec-scope-expansion-8810.md §4-§8, `fullnessTolerance = 0`
    /// per design-gate-release-bugB.md §3) is the only decision-maker —
    /// design-decision-b1-fallback-policy.md rule 1/5/6 forbid falling
    /// through to a looser resolution path just because that evaluator
    /// returned nothing. The ONE narrow exception is
    /// `resolveTextOnlyPreviousFallback(seed:window:cwd:)` below, reached
    /// only when the evaluator's own outcome says it couldn't even judge
    /// the click (a non-ASCII row, never a rejection) AND `purpose ==
    /// .click` — hover can never reach it, by the type system, not by
    /// convention (rule 2 condition 2).
    ///
    /// `rows`/`clickedIndex` may be a LARGER window than the evaluator
    /// needs (e.g. a caller's whole viewport capture) — this slices down
    /// to the shared `clickedIndex ± (maxWrappedRows - 1)` policy (7 rows
    /// total, matching ``TerminalPhysicalRowWindow/maxSnapshotRows``)
    /// itself, so click and hover produce byte-for-byte the same window
    /// shape regardless of how many rows each one happened to read —
    /// final-spec §13's row0/row1/row2 parity requirement holds at the
    /// SYSTEM level, not just between two calls already given identical
    /// windows.
    ///
    /// - Parameters:
    ///   - seed: The seed returned by
    ///     ``wrappedPathSeed(in:column:cwd:columns:)``, tokenized from
    ///     `rows[clickedIndex]`.
    ///   - rows: Physical rows, top to bottom, containing at least
    ///     `clickedIndex`.
    ///   - clickedIndex: The clicked row's position within `rows`.
    ///   - columns: The physical grid's column count — the SAME value
    ///     passed to `wrappedPathSeed(in:column:cwd:columns:)` for this
    ///     seed.
    ///   - cwd: The surface's working directory.
    ///   - purpose: Which surface is asking — see
    ///     ``TerminalWrappedResolutionPurpose``'s own doc. Required, no
    ///     default, so every call site states it explicitly.
    /// - Returns: The resolved candidate, or `nil` when the evaluator
    ///   rejected it, couldn't judge it and `purpose != .click`, or
    ///   couldn't judge it and the narrow fallback's own (independently
    ///   re-derived) eligibility still says no.
    public func resolveWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String,
        purpose: TerminalWrappedResolutionPurpose
    ) -> TerminalWrappedPathResolution? {
        resolveWrappedCandidateWithOutcome(
            seed: seed, rows: rows, clickedIndex: clickedIndex, columns: columns, cwd: cwd, purpose: purpose,
        ).candidate
    }

    /// Shared resolution entry with the geometry evaluator's structured
    /// outcome retained for DEBUG diagnostics. The candidate is exactly the
    /// value returned by ``resolveWrappedCandidate(seed:rows:clickedIndex:columns:cwd:purpose:)``;
    /// `evaluatorOutcome` is additional reporting data and never changes the
    /// purpose-specific fallback decision.
    public func resolveWrappedCandidateWithOutcome(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String,
        purpose: TerminalWrappedResolutionPurpose
    ) -> (candidate: TerminalWrappedPathResolution?, evaluatorOutcome: TerminalWrappedResolutionOutcome?) {
        resolveWrappedCandidateSharedEntryWithOutcome(
            seed: seed, rows: rows, clickedIndex: clickedIndex, columns: columns, cwd: cwd, purpose: purpose,
            probeBudget: TerminalWrapProbeBudget()
        ) ?? (candidate: nil, evaluatorOutcome: nil)
    }

    /// DEBUG diagnostics for the geometry-aware window evaluator. This is the
    /// evaluator's structured result before the purpose-specific click-only
    /// fallback is applied, so a caller can distinguish a judged rejection
    /// such as ``TerminalWrappedRejectionReason/fullnessGuardRejected`` from
    /// an unevaluable non-ASCII row. It does not make or alter a production
    /// resolution decision; the shared entry point below still owns that
    /// decision and its `purpose` handling.
    public func evaluateWrappedCandidateOutcome(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String
    ) -> TerminalWrappedResolutionOutcome? {
        evaluateWrappedCandidateOutcome(
            seed: seed, rows: rows, clickedIndex: clickedIndex, columns: columns, cwd: cwd,
            probeBudget: TerminalWrapProbeBudget()
        )
    }

    /// review R2-B2 — package-internal probe-budget-override entry, reachable
    /// from tests via `@testable import`: lets a fixture deterministically
    /// exhaust a SMALL injected budget on the way to what would
    /// otherwise be the winning candidate, instead of needing to
    /// contort a real-shaped fixture into spending the full 15-probe
    /// cap. Delegates to the exact same
    /// ``resolveWrappedCandidateSharedEntry(seed:rows:clickedIndex:columns:cwd:purpose:probeBudget:)``
    /// production's `purpose`-required overload above calls — never a
    /// parallel reimplementation.
    func resolveWrappedCandidate(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String,
        purpose: TerminalWrappedResolutionPurpose,
        maxProbes: Int
    ) -> TerminalWrappedPathResolution? {
        resolveWrappedCandidateSharedEntry(
            seed: seed, rows: rows, clickedIndex: clickedIndex, columns: columns, cwd: cwd, purpose: purpose,
            probeBudget: TerminalWrapProbeBudget(maxProbes: maxProbes)
        )
    }

    private func resolveWrappedCandidateSharedEntry(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String,
        purpose: TerminalWrappedResolutionPurpose,
        probeBudget: TerminalWrapProbeBudget
    ) -> TerminalWrappedPathResolution? {
        resolveWrappedCandidateSharedEntryWithOutcome(
            seed: seed, rows: rows, clickedIndex: clickedIndex, columns: columns, cwd: cwd, purpose: purpose,
            probeBudget: probeBudget
        )?.candidate
    }

    private func resolveWrappedCandidateSharedEntryWithOutcome(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String,
        purpose: TerminalWrappedResolutionPurpose,
        probeBudget: TerminalWrapProbeBudget
    ) -> (candidate: TerminalWrappedPathResolution?, evaluatorOutcome: TerminalWrappedResolutionOutcome)? {
        guard let (window, geometry) = wrappedCandidateEvaluationInput(
            rows: rows, clickedIndex: clickedIndex, columns: columns
        ) else { return nil }
        let outcome = evaluateContiguousSpans(
            seed: seed, window: window, cwd: cwd, geometry: geometry, probeBudget: probeBudget
        )

        switch outcome {
        case .resolved(let resolution):
            return (candidate: resolution, evaluatorOutcome: outcome)
        case .rejected:
            // design-decision-b1-fallback-policy.md rule 5 — a judged
            // rejection (fullness, ambiguity, absence, budget, shape,
            // row-local priority, ...) is a DECISION. Never a reason to
            // fall through to the legacy overload.
            return (candidate: nil, evaluatorOutcome: outcome)
        case .notEvaluable:
            // rule 2 condition 2 — hover structurally cannot reach the
            // fallback below; only `purpose == .click` may even attempt
            // it, and even then that attempt re-derives its own
            // eligibility rather than trusting this case alone.
            guard purpose == .click else { return (candidate: nil, evaluatorOutcome: outcome) }
            guard let fallback = resolveTextOnlyPreviousFallback(seed: seed, window: window, cwd: cwd) else {
                return (candidate: nil, evaluatorOutcome: outcome)
            }
            return (candidate: fallback, evaluatorOutcome: outcome)
        }
    }

    private func evaluateWrappedCandidateOutcome(
        seed: TerminalWrappedPathSeed,
        rows: [String],
        clickedIndex: Int,
        columns: Int,
        cwd: String,
        probeBudget: TerminalWrapProbeBudget
    ) -> TerminalWrappedResolutionOutcome? {
        guard let (window, geometry) = wrappedCandidateEvaluationInput(
            rows: rows, clickedIndex: clickedIndex, columns: columns
        ) else { return nil }

        return evaluateContiguousSpans(seed: seed, window: window, cwd: cwd, geometry: geometry, probeBudget: probeBudget)
    }

    private func wrappedCandidateEvaluationInput(
        rows: [String],
        clickedIndex: Int,
        columns: Int
    ) -> (window: TerminalPhysicalRowWindow, geometry: TerminalWrapGeometry)? {
        guard rows.indices.contains(clickedIndex) else { return nil }

        let windowStart = max(0, clickedIndex - (Self.maxWrappedRows - 1))
        let windowEnd = min(rows.count - 1, clickedIndex + (Self.maxWrappedRows - 1))
        let slicedRows = Array(rows[windowStart...windowEnd])
        let slicedClickedIndex = clickedIndex - windowStart

        guard let geometry = TerminalWrapGeometry(fullnessTolerance: 0),
              let window = TerminalPhysicalRowWindow(rows: slicedRows, clickedIndex: slicedClickedIndex, columns: columns),
              geometry.fullnessTolerance < window.columns
        else {
            return nil
        }
#if DEBUG
        debugResolutionObserver?(.windowPrepared)
#endif
        return (window, geometry)
    }

    /// design-decision-b1-fallback-policy.md rule 2/6 — the ONE, narrowly-
    /// named function permitted to fall back to a text-only join once the
    /// geometry-aware evaluator reports it couldn't judge a candidate at
    /// all (``TerminalWrappedResolutionOutcome/notEvaluable(_:)``). Called
    /// only from
    /// ``resolveWrappedCandidate(seed:rows:clickedIndex:columns:cwd:purpose:)``,
    /// and only for `purpose == .click` — every call site is therefore
    /// grep-auditable, and hover can never reach this by construction.
    ///
    /// This does NOT trust its caller's `.notEvaluable` classification as
    /// sufficient on its own — it re-derives every one of rule 2's
    /// conditions itself, using the SAME legacy, per-direction evaluator
    /// (`evaluateWrappedCandidate`) the pre-B1 code path used, so none of
    /// rule 4's guards (leading-piece shape, fragment-alone existence
    /// including the `explicitSlashSeam` exception, candidate shape,
    /// `fileExists` + cwd, exactly-one-direction) are relaxed:
    ///
    /// - The winning direction must be `.previous` — `resolveSingleDirection`
    ///   never takes the text-only branch for `.next` at all, so requiring
    ///   the win to be `.previous` also excludes a non-ASCII `.next` row
    ///   for free (rule 2 conditions 3/6): that row just fails its own
    ///   direction outright, exactly like any other rejection would.
    /// - The join is structurally 2-row (`previousRow`/`clickedRow` only —
    ///   `evaluateWrappedCandidate` cannot reach further) — rule 2
    ///   condition 4 holds by construction, not by a separate check.
    /// - The clicked row's own ASCII-ness (rule 2 condition 5) is already
    ///   guaranteed upstream (`wrappedPathSeed` can't produce a seed for a
    ///   non-ASCII clicked row at all) but is re-checked here anyway, so
    ///   this function's own safety never depends on that invariant
    ///   silently holding elsewhere.
    /// - review R2-B1/rule 2 condition 6 — only rows whose information this
    ///   two-row decision consumes must be ASCII. The clicked row is used
    ///   for terminal-cell tokenization and is therefore required to be
    ///   ASCII. The previous row is the explicit exception: its trailing
    ///   fragment is extracted textually and never projected onto cell
    ///   columns. A next row is required to be ASCII only when `seed`
    ///   names `.next`, because otherwise the exactly-one-direction
    ///   rule could mistake an unreadable competing candidate for no
    ///   candidate. Rows farther away in the evaluator's bounded window
    ///   are not consumed by this fallback and must not affect its result.
    /// - **The load-bearing check**: the result must carry
    ///   `cellSpans == .unavailableNonASCIIRow` (rule 3). This can only be
    ///   true when `resolveSingleDirection` ACTUALLY took the text-only
    ///   branch, which only happens for a genuinely non-ASCII previous
    ///   row — an all-ASCII candidate the geometry evaluator rejected for
    ///   any other reason (fullness, most of all) never sets this, so it
    ///   never reaches this function's success path. This is what keeps
    ///   rule 5 (fullness rejection never falls back) safe regardless of
    ///   which OTHER span, if any, the evaluator's own aggregate outcome
    ///   happened to key its `.rejected`/`.notEvaluable` classification
    ///   off of — the classification is a reporting aid, not the safety
    ///   mechanism.
    private func resolveTextOnlyPreviousFallback(
        seed: TerminalWrappedPathSeed,
        window: TerminalPhysicalRowWindow,
        cwd: String
    ) -> TerminalWrappedPathResolution? {
        let clickedIndex = window.clickedIndex
        guard clickedIndex > 0 else { return nil }
        // Revised rule 2 condition 6: check only the rows whose information
        // the fallback actually consumes. The previous row is deliberately
        // omitted; its text-only trailing fragment does not use cell
        // columns. Unrelated rows in the bounded evaluator window are
        // intentionally ignored.
        guard window.rows[clickedIndex].unicodeScalars.allSatisfy(\.isASCII) else {
            return nil
        }
        if seed.directions.contains(.next) {
            let nextIndex = clickedIndex + 1
            guard nextIndex < window.rows.count,
                  window.rows[nextIndex].unicodeScalars.allSatisfy(\.isASCII) else {
                return nil
            }
        }

        let previousRow = window.rows[clickedIndex - 1]
        let nextRow = clickedIndex + 1 < window.rows.count ? window.rows[clickedIndex + 1] : nil
        let evaluation = evaluateWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd)

        guard case .succeeded(let resolution) = evaluation.outcomes[.previous] else { return nil }
        // Exactly-one-direction still applies: if `.next` ALSO succeeded
        // (both directions ambiguous), `evaluation.candidate` is `nil`
        // even though `.previous` alone succeeded — this comparison
        // rejects that case rather than silently preferring `.previous`.
        guard evaluation.candidate == resolution else { return nil }
        guard resolution.cellSpans == .unavailableNonASCIIRow else { return nil }
        return resolution
    }

    /// issue #8810 symptom 1 — resolves a leading/bullet row when the
    /// clicked physical row itself is non-ASCII and therefore cannot yield
    /// a column-ranged ``TerminalWrappedPathSeed``. This is deliberately a
    /// separate path from ``resolveTextOnlyPreviousFallback(seed:window:cwd:)``:
    /// the latter handles a click on the ASCII continuation row, while this
    /// handles a click on the leading row.
    ///
    /// A row accepted by ``TerminalRowCellLayout`` takes the exact branch:
    /// both click and hover are allowed, the fabricated zero-width seed is
    /// avoided, and the evaluator returns `.available` real cell spans. Rows
    /// outside that proof remain the conservative click-only branch with a
    /// 2× scalar upper bound and `.unavailableNonASCIIRow`.
    public func resolveTextOnlyLeadingRowFallback(
        clickedRow: String,
        column: Int,
        nextRow: String?,
        cwd: String,
        purpose: TerminalWrappedResolutionPurpose
    ) -> TerminalWrappedPathResolution? {
        guard let nextRow else { return nil }
        guard !clickedRow.unicodeScalars.allSatisfy(\.isASCII) else { return nil }

        let characters = Array(clickedRow)
        guard let bodyStart = characters.firstIndex(where: { $0.unicodeScalars.allSatisfy(\.isASCII) }) else {
            return nil
        }
        let prefix = characters[..<bodyStart]
        // `column` is a terminal-cell coordinate while `characters` is a
        // Swift Character array. There is no authoritative Ghostty width in
        // this text-only API, so use a conservative upper bound: two cells
        // per prefix scalar. A false negative is preferable to treating an
        // ambiguous-width prefix cell as an ASCII body click.
        let prefixCellUpperBound = prefix.reduce(into: 0) { width, character in
            width += max(1, character.unicodeScalars.count * 2)
        }
        let body = characters[bodyStart...]
        guard body.allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) }) else { return nil }

        let pathTokenSlices = body
            .split(whereSeparator: { $0.isWhitespace })
            .filter { String($0).isWrappedPathPrefixShaped }
        guard pathTokenSlices.count == 1, let pathTokenSlice = pathTokenSlices.first else { return nil }
        let token = String(pathTokenSlice)
        // Row-local priority must not reinterpret a terminal-cell column as a
        // Swift String index. Resolve the unique body token itself instead;
        // if it already exists, this is not a wrapped candidate.
        guard resolveQuicklookPath(token, cwd: cwd) == nil else { return nil }

        if let layout = TerminalRowCellLayout.verified(for: clickedRow) {
            // The identity proof is deliberately local to this fallback;
            // `wrappedPathSeed`/`resolveVisibleLinePath` retain their
            // conservative ASCII-only contracts until native cell provenance
            // replaces this seam.
            guard let tokenCellRange = layout.cellRange(forCharacterOffsets: pathTokenSlice.startIndex..<pathTokenSlice.endIndex),
                  tokenCellRange.contains(column) else {
                return nil
            }

            let seed = TerminalWrappedPathSeed(
                directions: [.next],
                token: token,
                tokenStartColumn: tokenCellRange.lowerBound,
                tokenEndColumn: tokenCellRange.upperBound,
                disposition: .noRowLocalHit
            )
            let evaluation = evaluateWrappedCandidate(
                seed: seed,
                previousRow: nil,
                nextRow: nextRow,
                cwd: cwd
            )
            guard case .succeeded(let resolution) = evaluation.outcomes[.next],
                  evaluation.candidate == resolution,
                  case .available = resolution.cellSpans else {
                return nil
            }
            return resolution
        }

        // The conservative branch has no trustworthy cell range. It is
        // click-only and keeps the old upper-bound admission rule: a false
        // negative is preferable to treating an ambiguous-width prefix cell
        // as an ASCII body click.
        guard purpose == .click,
              column >= prefixCellUpperBound else {
            return nil
        }

        // The leading row has no trustworthy cell range. The existing
        // evaluator only needs the token text for its `.next` guards; the
        // fabricated range is discarded when the successful resolution is
        // re-expressed as `.unavailableNonASCIIRow` below.
        let seed = TerminalWrappedPathSeed(
            directions: [.next],
            token: token,
            tokenStartColumn: 0,
            tokenEndColumn: 0,
            disposition: .noRowLocalHit
        )
        let evaluation = evaluateWrappedCandidate(
            seed: seed,
            previousRow: nil,
            nextRow: nextRow,
            cwd: cwd
        )
        guard case .succeeded(let resolution) = evaluation.outcomes[TerminalWrapDirection.next],
              evaluation.candidate == resolution else {
            return nil
        }

        return TerminalWrappedPathResolution(
            path: resolution.path,
            nativeMatchKeys: resolution.nativeMatchKeys,
            cellSpans: .unavailableNonASCIIRow
        )
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

    /// design-decision B5 — computes the exact standardized (tilde-
    /// expanded, cwd-resolved, `standardizingPath`-applied) candidate path
    /// `raw` would probe to, WITHOUT touching the file system. The single
    /// place both ``probeExists(_:cwd:)`` and the contiguous-span
    /// evaluator's own probe cache derive this from, so two different raw
    /// spellings that resolve to the same real path are recognized as the
    /// SAME probe BEFORE any `fileExists` call, not after (final-spec §8
    /// rule 2's "同一のstandardized pathを1回だけprobe" contract).
    private func standardizedCandidatePath(_ raw: String, cwd: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        let candidatePath: String
        if expanded.hasPrefix("/") {
            candidatePath = expanded
        } else {
            guard !cwd.isEmpty else { return nil }
            candidatePath = (cwd as NSString).appendingPathComponent(expanded)
        }
        return (candidatePath as NSString).standardizingPath
    }

    /// A single, exact-candidate existence probe: expands `~`, resolves
    /// against `cwd` when relative, standardizes, and checks existence
    /// once. Deliberately not ``resolveQuicklookPath(_:cwd:)``, which tries
    /// multiple punctuation-trimmed variants — that would silently multiply
    /// the wrapped-candidate I/O budget past its documented per-direction
    /// probe count.
    private func probeExists(_ raw: String, cwd: String) -> String? {
        guard let standardized = standardizedCandidatePath(raw, cwd: cwd) else { return nil }
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
    /// design-decision-b1-fallback-policy.md rule 1 — unlike a plain
    /// `Bool`, this also distinguishes "measured and it's short" from
    /// "couldn't measure at all" (a non-ASCII `upperRow`), which is
    /// exactly the distinction ``TerminalWrappedResolutionOutcome`` needs
    /// at the boundary level to avoid conflating a genuine fullness
    /// rejection with a row this heuristic simply can't see into.
    private enum WrapBoundaryVerdict: Equatable {
        case full
        case notFull
        case notEvaluable
    }

    private protocol WrapBoundaryOracle {
        /// - Parameters:
        ///   - upperRow: The physical row immediately above the boundary.
        ///   - lowerRow: The physical row immediately below the boundary
        ///     — carried for a future native implementation that may
        ///     need it; the current text heuristic only ever inspects
        ///     `upperRow`.
        ///   - columns: The physical grid's column count.
        func evaluateBoundary(upperRow: String, lowerRow: String, columns: Int) -> WrapBoundaryVerdict
    }

    /// The current, only ``WrapBoundaryOracle`` implementation: strict
    /// physical right edge, with a configurable tolerance
    /// (final-spec-scope-expansion-8810.md §1/§2.2) — byte-for-byte the
    /// same judgment `evaluateContiguousSpans` made inline before this
    /// seam existed, now additionally reporting `.notEvaluable` instead of
    /// silently folding a non-ASCII `upperRow` into `.notFull` (that
    /// conflation was B1's root cause: a non-ASCII adjacent row and a
    /// genuinely-not-full ASCII row both used to collapse to the same
    /// bare `false`).
    private struct TextHeuristicWrapBoundaryOracle: WrapBoundaryOracle {
        let fullnessTolerance: Int

        func evaluateBoundary(upperRow: String, lowerRow: String, columns: Int) -> WrapBoundaryVerdict {
            guard upperRow.unicodeScalars.allSatisfy(\.isASCII) else { return .notEvaluable }
            guard let lastColumn = upperRow.lastNonWhitespaceColumn else { return .notFull }
            return lastColumn >= columns - 1 - fullnessTolerance ? .full : .notFull
        }
    }

    /// final-spec §4 — enumerates every structurally-eligible contiguous
    /// row span (length 2...``maxWrappedRows``) containing
    /// `window.clickedIndex`, evaluates each independently, and adopts the
    /// unique dominating success (§4.3). `geometry` is always non-`nil`
    /// here — the `nil` fallback is handled by the caller before this is
    /// ever reached.
    ///
    /// design-decision-b1-fallback-policy.md rule 1 — returns a
    /// structured ``TerminalWrappedResolutionOutcome`` instead of a bare
    /// optional. The `.rejected`/`.notEvaluable` classification below is a
    /// REPORTING aid (which reason to surface when nothing succeeds), not
    /// itself the safety mechanism: `resolveTextOnlyPreviousFallback`
    /// independently re-derives whether ITS OWN narrow 2-row join is
    /// actually eligible, so an imprecise aggregate classification here
    /// (e.g. an unrelated span's fullness rejection outranking a
    /// genuinely-non-ASCII adjacent row elsewhere in the same search)
    /// can never itself admit an unsafe fallback — see that function's
    /// own doc for why.
    /// - Parameter probeBudget: Defaults to the real 15-probe cap;
    ///   review R2-B2 — a test-only smaller override lets a fixture
    ///   deterministically exhaust the budget without needing to spend
    ///   the full real cap.
    private func evaluateContiguousSpans(
        seed: TerminalWrappedPathSeed,
        window: TerminalPhysicalRowWindow,
        cwd: String,
        geometry: TerminalWrapGeometry,
        probeBudget: TerminalWrapProbeBudget = TerminalWrapProbeBudget()
    ) -> TerminalWrappedResolutionOutcome {
#if DEBUG
        debugResolutionObserver?(.evaluatorInvoked)
#endif
        let clickedIndex = window.clickedIndex
        let oracle: any WrapBoundaryOracle = TextHeuristicWrapBoundaryOracle(fullnessTolerance: geometry.fullnessTolerance)
        var probeBudget = probeBudget
        // final-spec §8 rule 2: the SAME raw fragment/candidate probed by
        // more than one span (e.g. the same `spanStart` fragment reused
        // across several `spanEnd` choices) is only ever probed once.
        // design-decision B5 — keyed on the STANDARDIZED path (computed
        // before any cache lookup, never after), so two different raw
        // spellings that resolve to the same real path collapse to one
        // probe instead of two.
        var probeCache: [String: String?] = [:]

        func probe(_ raw: String) -> String? {
            guard let standardized = standardizedCandidatePath(raw, cwd: cwd) else { return nil }
            if let cached = probeCache[standardized] { return cached }
            guard probeBudget.consume() else { return nil }
            let result = fileExists(standardized) ? standardized : nil
            probeCache[standardized] = result
            return result
        }

        // final-spec §5.1: pure, boundary-local — never a property of
        // which row was clicked (see that section's own "クリック行の属性に
        // してはいけません" note, which is exactly why this takes two rows
        // and never the seed/clicked index).
        func mirrorSlashSeam(upperRow: String, lowerRow: String) -> Bool {
            guard oracle.evaluateBoundary(upperRow: upperRow, lowerRow: lowerRow, columns: window.columns) == .full else {
                return false
            }
            return lowerRow.leadingContinuationFragmentWithRange(
                maxIndentation: Self.maxContinuationIndentation
            )?.fragment.hasPrefix("/") == true
        }

        // final-spec §4.1: derive every row's canonical contribution from
        // its position in the candidate span, independently of which row
        // was clicked. The leading row contributes its trailing fragment;
        // every continuation row contributes its bounded leading fragment
        // and must consume all non-padding text on that row.
        func piece(at row: Int, spanStart: Int) -> SpanPiece? {
            let canonicalPiece: SpanPiece
            if row == spanStart {
                guard let match = window.rows[row].trailingContinuationFragmentWithRange() else { return nil }
                canonicalPiece = SpanPiece(text: match.fragment, startColumn: match.startColumn, endColumn: match.endColumn)
            } else {
                guard let match = window.rows[row].leadingContinuationFragmentWithRange(
                    maxIndentation: Self.maxContinuationIndentation
                ) else { return nil }
                guard let trimmed = window.rows[row].gridPaddingTrimmedWithRange(),
                      trimmed.fragment == match.fragment,
                      trimmed.startColumn == match.startColumn,
                      trimmed.endColumn == match.endColumn else { return nil }
                canonicalPiece = SpanPiece(text: match.fragment, startColumn: match.startColumn, endColumn: match.endColumn)
            }
            if row == clickedIndex {
                guard seed.tokenStartColumn >= canonicalPiece.startColumn,
                      seed.tokenEndColumn <= canonicalPiece.endColumn else { return nil }
            }
            return canonicalPiece
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
                return .rejected(.rowLocalPriorityBypass)
            }
        }

        // issue #8810 revised ruling — `.explicitTrailingSlashSeamBypass`
        // searches downward through the same max-four-row bound as the
        // mirror-seam disposition. The boundary-local seam checks below
        // keep the expansion tied to the clicked piece's own legacy slash
        // seam while preserving the existing row-local and candidate-shape
        // guards.
        let minStart: Int
        let maxEnd: Int
        switch seed.disposition {
        case .rowLocalHitAwaitingMirrorSlashSeam:
            minStart = clickedIndex
            maxEnd = min(window.rows.count - 1, clickedIndex + (Self.maxWrappedRows - 1))
        case .explicitTrailingSlashSeamBypass:
            minStart = clickedIndex
            maxEnd = min(window.rows.count - 1, clickedIndex + (Self.maxWrappedRows - 1))
        case .noRowLocalHit:
            minStart = max(0, clickedIndex - (Self.maxWrappedRows - 1))
            maxEnd = min(window.rows.count - 1, clickedIndex + (Self.maxWrappedRows - 1))
        }

        var successes: [SpanSuccess] = []
        // design-decision-b1-fallback-policy.md rule 1 — aggregate
        // reporting only (see this function's own doc for why the SAFETY
        // of the click-only fallback never depends on this being
        // perfectly precise). `notEvaluableSeen` outranks `rejection`
        // when both are set: a genuinely non-ASCII row anywhere in the
        // search is reported as "couldn't judge," even if some OTHER,
        // unrelated span was independently rejected outright.
        var rejection: TerminalWrappedRejectionReason?
        var notEvaluableSeen = false
        func recordRejection(_ reason: TerminalWrappedRejectionReason) {
            if rejection == nil { rejection = reason }
        }
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
                var fullnessNotEvaluable = false
                for boundary in spanStart..<spanEnd {
                    switch oracle.evaluateBoundary(
                        upperRow: window.rows[boundary], lowerRow: window.rows[boundary + 1], columns: window.columns
                    ) {
                    case .full:
                        continue
                    case .notFull:
                        fullnessOK = false
                    case .notEvaluable:
                        fullnessOK = false
                        fullnessNotEvaluable = true
                    }
                    break
                }
                guard fullnessOK else {
                    if fullnessNotEvaluable {
                        notEvaluableSeen = true
                    } else {
                        recordRejection(.fullnessGuardRejected)
                    }
                    continue
                }

                var pieces: [SpanPiece] = []
                var extractionOK = true
                var extractionNotEvaluable = false
                for row in spanStart...spanEnd {
                    guard let piece = piece(at: row, spanStart: spanStart),
                          piece.text.count <= Self.maxWrappedFragmentLength else {
                        extractionOK = false
                        if !window.rows[row].unicodeScalars.allSatisfy(\.isASCII) {
                            extractionNotEvaluable = true
                        }
                        break
                    }
                    pieces.append(piece)
                }
                guard extractionOK, let leadingPiece = pieces.first, let trailingPiece = pieces.last else {
                    if extractionNotEvaluable {
                        notEvaluableSeen = true
                    } else {
                        recordRejection(.fragmentNotExtractable)
                    }
                    continue
                }

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
                // boundary. The continuation piece is extracted through the
                // bounded indentation gate, so the leading seam must use
                // that same gate rather than collapsing the confirmed
                // two-space capture to col-0.
                let leadingBoundaryHasLegacySlashSeam = spanStart < spanEnd &&
                    leadingPiece.text.hasSuffix("/") &&
                    pieces[1].startColumn <= Self.maxContinuationIndentation

                // This asymmetry is deliberate. On the trailing side, a
                // col-0 continuation is the legacy slash exception; an
                // indented final fragment must remain independently probed
                // so a directory listing cannot be mistaken for a joined
                // path. The trailing-side col-0 pin preserves that
                // fragment-alone rejection behavior.
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
                    || leadingPiece.text.isWrappedPathPrefixShaped else {
                    recordRejection(.leadingPieceNotPathPrefixShaped)
                    continue
                }

                let candidateRaw = pieces.map(\.text).joined()
                guard candidateRaw.utf8.count <= Self.maxWrappedCandidateBytes else {
                    recordRejection(.candidateTooLong)
                    continue
                }
                guard candidateRaw.isWrappedPathCandidateShaped else {
                    recordRejection(.candidateNotPathShaped)
                    continue
                }

                // final-spec §8 rule 3 — candidate existence is probed
                // BEFORE the endpoint fragment-alone probes, so a span
                // whose joined candidate doesn't exist never spends probes
                // on fragment-alone checks it can no longer affect.
                guard let standardizedPath = probe(candidateRaw) else {
                    recordRejection(probeBudget.hasRemaining ? .candidateDoesNotExist : .probeBudgetExceeded)
                    continue
                }

                // final-spec §4.2 — fragment-alone-exists applies only to
                // the two OUTER endpoints, and only when that endpoint
                // isn't the clicked row itself (§8 rule 1: never re-probe
                // the clicked token alone) — bypassed at a mirror-seam or
                // legacy-slash-seam boundary.
                if spanStart != clickedIndex, !leadingBoundaryHasMirrorSeam, !leadingBoundaryHasLegacySlashSeam,
                   probe(leadingPiece.text) != nil {
                    recordRejection(.fragmentAloneExists)
                    continue
                }
                if spanEnd != clickedIndex, !trailingBoundaryHasMirrorSeam, !trailingBoundaryHasLegacySlashSeam,
                   probe(trailingPiece.text) != nil {
                    recordRejection(.fragmentAloneExists)
                    continue
                }

                successes.append(SpanSuccess(range: spanStart...spanEnd, standardizedPath: standardizedPath, pieces: pieces))
            }
        }

        guard !successes.isEmpty else {
            if notEvaluableSeen { return .notEvaluable(.nonASCIIRowPreventsCellColumns) }
            return .rejected(rejection ?? .candidateDoesNotExist)
        }

        // final-spec §4.3 — the unique span containing every other
        // success's row range dominates; anything else (including zero
        // such spans, i.e. genuinely incomparable successes) fails closed.
        let dominating = successes.filter { candidate in
            successes.allSatisfy { other in
                other.range.lowerBound >= candidate.range.lowerBound && other.range.upperBound <= candidate.range.upperBound
            }
        }
        guard dominating.count == 1, let winner = dominating.first else {
            return .rejected(.spanAmbiguous)
        }

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
        return .resolved(TerminalWrappedPathResolution(
            path: winner.standardizedPath, nativeMatchKeys: keys, cellSpans: .available(cellSpans)
        ))
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

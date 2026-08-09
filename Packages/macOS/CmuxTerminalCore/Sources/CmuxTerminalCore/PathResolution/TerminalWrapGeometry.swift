// final-spec-scope-expansion-8810.md §2/§3. Value types for issue #8810's
// two scope expansions (3+ row hard-wrap support, bidirectional
// `/`-continuation search): the physical-row window/snapshot types, the
// fullness-guard tunable, the probe budget, and the row-local disposition
// classification. The multi-row contiguous-span evaluator, mirror-slash-
// seam predicate, and B1's outcome/rejection-reason types that actually
// consume these live in `TerminalPathResolver.swift`.

/// final-spec §2.1 — a physical-row window: `rows` in physical top-to-
/// bottom order, which one is the clicked row, and the single owner of
/// `columns` for this window. A pure Core value type; the initializer
/// validates row order/clicked-index bounds, column validity, and the
/// snapshot row-count cap so an invalid combination can never be
/// constructed.
///
/// `columns` lives ONLY here (never duplicated onto
/// ``TerminalWrapGeometry``) so "window and geometry disagree about
/// columns" is not a state the type system can even represent — see
/// ``TerminalWrapGeometry``'s own doc.
public struct TerminalPhysicalRowWindow: Sendable, Equatable {
    /// Physical rows, top to bottom. Never empty (enforced by `init?`).
    public let rows: [String]
    /// The clicked row's position within `rows`.
    public let clickedIndex: Int
    /// The single owner of the physical grid's column count for this
    /// window.
    public let columns: Int

    /// Maximum rows a window may hold — mirrors
    /// ``TerminalPhysicalRowsSnapshot/maxSnapshotRows``; hover needs at
    /// most `maxWrappedRows - 1` rows above and below the clicked row
    /// (`2 * 4 - 1 = 7`), and Ghostty's own `max_snapshot_rows` caps at 8
    /// (`ghostty/src/renderer/link.zig`), so 7 stays within that budget.
    public static let maxSnapshotRows = 7

    /// - Returns: `nil` if `rows` is empty, `clickedIndex` doesn't index
    ///   into `rows`, `columns <= 0`, or `rows.count` exceeds
    ///   ``maxSnapshotRows``.
    public init?(rows: [String], clickedIndex: Int, columns: Int) {
        guard !rows.isEmpty,
              clickedIndex >= 0, clickedIndex < rows.count,
              columns > 0,
              rows.count <= Self.maxSnapshotRows
        else { return nil }
        self.rows = rows
        self.clickedIndex = clickedIndex
        self.columns = columns
    }
}

/// final-spec §2.2 — the multi-row/mirror-slash-seam evaluator's tunable
/// geometry: fullness tolerance only. Deliberately carries NO `columns`
/// field — `TerminalPhysicalRowWindow` is the sole owner of that (see its
/// doc) — so "the window's columns and the geometry's columns disagree"
/// cannot be constructed as two independently-settable fields. The one
/// place `tolerance >= columns` needs checking is the evaluator's own
/// entry point, where both a window (with its `columns`) and a geometry
/// are available together.
///
/// final-spec §1: strict physical edge is the adopted policy — the
/// default (and, for this pass, only realistic) tolerance is `0`; `1` is
/// a hard cap reserved for a future pass IF real-machine dogfood logs
/// (gated on bug B's root-cause confirmation, final-spec §12) show a
/// genuine formatter/selection-driven 1-cell fullness discrepancy. Inner
/// margins are never absorbed via a larger tolerance, and "the maximum
/// non-whitespace column observed in the viewport" is never treated as a
/// dynamic wrap width — both were explicitly rejected alternatives.
public struct TerminalWrapGeometry: Sendable, Equatable {
    /// How many trailing columns short of the physical right edge still
    /// counts as "reached the edge" for the fullness guard. `0` (strict)
    /// by default; `1` is the only other value initializer accepts.
    public let fullnessTolerance: Int

    /// - Returns: `nil` if `fullnessTolerance` is negative or exceeds `1`.
    public init?(fullnessTolerance: Int = 0) {
        guard fullnessTolerance >= 0, fullnessTolerance <= 1 else { return nil }
        self.fullnessTolerance = fullnessTolerance
    }
}

/// final-spec §2.3 — a physical-row snapshot read under one lease/lock
/// section, holding BOTH the exact raw bytes the setter must forward
/// (`rawText`) and the resolver-ready split `rows` — see the type's own
/// "byte-for-byte" requirement below. This is the ONLY way a
/// `TerminalPhysicalRowWindow` should be constructed in production: both
/// `rows` and `columns` here come from the SAME coherent read, so a
/// caller building a window from mismatched sources (e.g. a cached
/// `columns` alongside a freshly re-read `rows`) is structurally avoided
/// by routing everything through one snapshot value.
///
/// `rawText` is NOT "whatever `rows.joined(separator: "\n")` would
/// produce" — it is the literal text the host read from
/// `ghostty_surface_read_text_physical_rows`, which Ghostty itself
/// hashes byte-for-byte into a `PhysicalSnapshotToken` for render-time
/// validity (`ghostty/src/Surface.zig`'s `setExternalLinkHover`). A
/// trailing-newline sentinel or short-read end padding that
/// `splitPhysicalViewportRows` normalizes away when producing `rows`
/// would NOT be reproducible byte-for-byte by re-joining `rows` — so the
/// setter/cache path must always use `rawText`, never reconstruct it.
public struct TerminalPhysicalRowsSnapshot: Sendable, Equatable {
    /// The exact text read from the surface — the only value the setter/
    /// cache path may forward; never reconstructed from `rows`.
    public let rawText: String
    /// `rawText` split into exactly `rowCount` normalized rows, ready for
    /// the resolver (see `String.splitPhysicalViewportRows(expectedRows:)`).
    public let rows: [String]
    /// The viewport-relative physical row this snapshot's first row
    /// starts at.
    public let topRow: UInt32
    public let columns: Int

    /// Computed, never a second stored source of truth for the row
    /// count — see final-spec §11's explicit "no double ownership" note.
    public var rowCount: UInt32 { UInt32(rows.count) }

    /// Maximum rows a snapshot may hold — see
    /// ``TerminalPhysicalRowWindow/maxSnapshotRows``'s doc for the exact
    /// figure's derivation; the two types share the same cap.
    public static let maxSnapshotRows = TerminalPhysicalRowWindow.maxSnapshotRows

    /// - Returns: `nil` if `columns <= 0`, `expectedRowCount == 0`,
    ///   `expectedRowCount` exceeds ``maxSnapshotRows``, or
    ///   `rawText.splitPhysicalViewportRows(expectedRows:)` itself fails
    ///   to reconcile `rawText` with `expectedRowCount`.
    public init?(
        rawText: String,
        topRow: UInt32,
        expectedRowCount: UInt32,
        columns: Int
    ) {
        guard columns > 0,
              expectedRowCount > 0,
              expectedRowCount <= UInt32(Self.maxSnapshotRows),
              let splitRows = rawText.splitPhysicalViewportRows(expectedRows: Int(expectedRowCount))
        else { return nil }
        self.rawText = rawText
        self.rows = splitRows
        self.topRow = topRow
        self.columns = columns
    }
}

/// final-spec §2.4 — an internal (not part of the public resolver API)
/// bounded budget for the multi-row evaluator's `fileExists` calls.
/// final-spec §8 derives the worst case (9 joined-candidate probes + 6
/// fragment-alone probes = 15) the evaluator's own dedup/reordering
/// rules must stay within; this type is the mechanical enforcement of
/// that cap, not itself the policy that keeps real usage under it.
struct TerminalWrapProbeBudget {
    static let maxProbes = 15

    private var remaining: Int

    /// - Parameter maxProbes: review R2-B2 — test-only override so a
    ///   fixture can deterministically exhaust a SMALL budget instead of
    ///   needing to spend the full real 15-probe cap; production always
    ///   uses the default (``Self/maxProbes``).
    init(maxProbes: Int = TerminalWrapProbeBudget.maxProbes) {
        remaining = maxProbes
    }

    /// Consumes one probe if budget remains.
    /// - Returns: `true` if a probe may proceed (and one unit of budget
    ///   was just consumed); `false` if the budget is already exhausted
    ///   — the caller must treat this exactly like a failed probe (fail
    ///   closed), never retry, never silently skip the budget check.
    mutating func consume() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }

    /// design-decision-b1-fallback-policy.md rule 1 — whether a probe
    /// that just returned `nil` did so because the path genuinely doesn't
    /// exist, or because the budget was already exhausted before it could
    /// even be checked. Read immediately after a failed `consume()`-gated
    /// probe; the evaluator uses this to classify the rejection as
    /// ``TerminalWrappedRejectionReason/probeBudgetExceeded`` vs
    /// ``TerminalWrappedRejectionReason/candidateDoesNotExist``.
    var hasRemaining: Bool { remaining > 0 }
}

/// final-spec §3 — which of three states `wrappedPathSeed`'s row-local
/// check left the click in, for the geometry-aware evaluator to route on.
/// A pure classification value; computing it does not itself decide
/// whether a wrapped candidate is produced (that's the evaluator's job,
/// landing in a later pass per final-spec §12).
public enum TerminalRowLocalDisposition: Sendable, Equatable {
    /// No row-local hit at all — the ordinary cross-row search applies,
    /// and (once the evaluator lands) may span multiple rows.
    case noRowLocalHit

    /// The existing bug A exception: the clicked token itself ends with
    /// an explicit trailing `/`. The original final-spec §3.1
    /// adjacent-only ruling is superseded by issue #8810's revised rule:
    /// length-two spans retain the old behavior, while a length-three-plus
    /// span is licensed only when its leading boundary is the clicked piece's
    /// legacy slash seam (the piece ends `/` and the next piece starts at
    /// column 0). This disposition may therefore participate in the same
    /// bounded, exact cell-span path used by hover once that guard holds.
    case explicitTrailingSlashSeamBypass

    /// A row-local hit exists, but the clicked token reaches the strict
    /// physical right edge, so a "mirror slash seam" (final-spec §5) may
    /// still apply at the boundary immediately after the clicked row.
    /// final-spec §3.2: the ordinary cross-row search is FORBIDDEN in
    /// this state — only the tightly-scoped mirror-seam path (landing in
    /// a later pass) may produce a candidate; if that doesn't apply, the
    /// existing row-local path is used unchanged.
    case rowLocalHitAwaitingMirrorSlashSeam
}

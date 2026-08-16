public import Foundation
public import CmuxTerminalCore

/// (B) ExternalHover — a viewport-relative grid cell, decoupled from any
/// AppKit view's own private cell type (wired to one in a later pass).
public struct ExternalHoverGridCell: Sendable, Equatable {
    public let row: UInt32
    public let column: Int

    public init(row: UInt32, column: Int) {
        self.row = row
        self.column = column
    }
}

/// (B) ExternalHover — the actor-owned cache for one runtime lifetime.
/// Holds everything `ExternalHoverWorkService` needs to re-present the
/// SAME setter call for a different cell within the same resolved
/// candidate, without re-reading, re-tokenizing, or re-probing the
/// filesystem (review Blocking 3/6).
///
/// `ranges` are already materialized to ABSOLUTE VIEWPORT coordinates
/// (review Blocking 6's recommended fix) — never row-relative-to-clicked
/// `TerminalWrappedPathCellSpan`s, so `contains(cell:)` takes exactly the
/// one argument it needs.
struct ExternalHoverCandidateCache: Sendable {
    let lifetimeID: RuntimeSurfaceLifetimeID
    let cwd: String
    /// Viewport-relative physical-row scope the setter call used —
    /// matches Ghostty's own `top_row`/`row_count` contract exactly (see
    /// `renderer/link.zig`).
    let topRow: UInt32
    let rowCount: UInt32
    /// The exact physical-row text the activation token (once minted) was
    /// fingerprinted over — needed verbatim to re-present the SAME setter
    /// call for a same-range cell move.
    let physicalRowsText: String
    let ranges: [ExternalHoverCellRangeValue]
    let path: String
    /// `nil` until the setter has actually minted one; renamed from an
    /// earlier draft's `physicalToken` per review Blocking 3 — this is the
    /// activation token, not a bare snapshot token.
    var activationToken: HoverActivationTokenValue?

    /// Whether `cell` falls within any of this cache's already-absolute
    /// `ranges` — a pure, single-argument check (review Blocking 6): no
    /// `clickedRow`/`topRow` conflation is possible since `ranges` never
    /// carries anything but final absolute coordinates.
    func contains(cell: ExternalHoverGridCell) -> Bool {
        ranges.contains { range in
            UInt32(range.row) == cell.row
                && cell.column >= Int(range.startColumn)
                && cell.column < Int(range.endColumn)
        }
    }
}

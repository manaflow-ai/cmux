public import Foundation

/// A pending request to re-assert keyboard focus on the originating panel
/// after a non-focusing split is created next to it.
///
/// Non-focusing splits (for example a programmatic browser split) must leave
/// focus on the panel the user was working in; AppKit focus can drift during
/// the layout pass, so the workspace records this request and re-asserts the
/// preferred panel when the layout settles. The `generation` token guards
/// against a stale re-assert firing after a newer split superseded it.
/// Formerly `Workspace.PendingNonFocusSplitFocusReassert`.
public struct PendingNonFocusSplitFocusReassert: Sendable, Equatable {
    /// Monotonic token identifying this re-assert request; a stale generation
    /// must not clear or apply a newer pending request.
    public let generation: UInt64
    /// The panel that should retain keyboard focus once layout settles.
    public let preferredPanelId: UUID
    /// The newly created (non-focused) split panel this request guards.
    public let splitPanelId: UUID

    /// Creates a pending focus re-assert request.
    public init(generation: UInt64, preferredPanelId: UUID, splitPanelId: UUID) {
        self.generation = generation
        self.preferredPanelId = preferredPanelId
        self.splitPanelId = splitPanelId
    }
}

public import CoreGraphics

/// A surface's answer to a drag hovering at a screen point.
public nonisolated struct TabDropProposal: Hashable, Sendable {
    public var kind: TabDropKind
    /// Screen frame to highlight (drop zone, gap, sidebar row).
    public var highlightFrame: CGRect
    /// Screen frame the ghost should collapse into (an inline tab slot), or
    /// nil to keep the floating preview card.
    public var ghostFrame: CGRect?
    /// The surface itself refuses the drop here (a sidebar row of another
    /// machine, the pinned area): the localized reason. `kind` is then
    /// only the nearest kind the surface knows; it never runs.
    public var refusedReason: String?

    public init(kind: TabDropKind, highlightFrame: CGRect, ghostFrame: CGRect? = nil, refusedReason: String? = nil) {
        self.kind = kind
        self.highlightFrame = highlightFrame
        self.ghostFrame = ghostFrame
        self.refusedReason = refusedReason
    }
}

/// Implemented by every surface a tab can be dropped on (tab strips, the
/// layout, the sidebar). The drag session calls `dropHitTest` on every
/// pointer move, `dropExited` when the pointer leaves a surface that
/// answered before, and `dropEnded` once when the drag finishes.
@MainActor
public protocol TabDropTargetProviding: AnyObject {
    /// The proposal for `payload` at `screenPoint`, or nil when this surface
    /// does not accept it there. May update live feedback (open a gap).
    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal?
    /// The pointer left this surface: remove live feedback.
    func dropExited()
    /// The drag finished. `committed` is the proposal the session executed
    /// if it was this surface's, else nil (cancelled or dropped elsewhere).
    func dropEnded(committed: TabDropProposal?)
}

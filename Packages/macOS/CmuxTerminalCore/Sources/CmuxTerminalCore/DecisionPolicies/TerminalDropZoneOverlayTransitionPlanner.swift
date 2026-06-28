public import CoreGraphics

/// Pure branch-selection for a terminal surface's drop-zone hover overlay.
///
/// This is the terminal-domain home of the decision tree that lived inside
/// `GhosttyNSView.setDropZoneOverlay(zone:)`. The witness keeps every AppKit
/// side effect (the main-thread hop, the `activeDropZone`/`pendingDropZone`
/// stored state, `attachDropZoneOverlayIfNeeded()`, the container-converting
/// `dropZoneOverlayFrame(for:in:)` measurement, the `NSAnimationContext`
/// sequences, and the `dropZoneOverlayAnimationGeneration` bookkeeping). It
/// resolves the live conditions to plain values and asks this type only which
/// `DropZoneOverlayTransition` to run, so the decision stays a deterministic,
/// testable value computation that references no AppKit.
///
/// The decision is split across two entry points because a side effect sits
/// between them in the witness: the degenerate-bounds defer is decided *before*
/// `attachDropZoneOverlayIfNeeded()` reparents the overlay, while the
/// show/update/raise/hide decision needs the *post*-attach measured frames.
public enum TerminalDropZoneOverlayTransitionPlanner: Sendable {
    /// Pre-attach gate: a requested zone on degenerate bounds defers.
    ///
    /// Returns `.deferZeroBounds` when a zone is requested while the bounds are
    /// too small (≤ 2pt on either axis), so the witness can stash the pending
    /// zone and return before attaching/measuring. Returns `nil` when the
    /// witness should proceed to attach, measure, and call `transition`.
    public static func deferralTransition(
        hasZone: Bool,
        boundsTooSmall: Bool
    ) -> DropZoneOverlayTransition? {
        (hasZone && boundsTooSmall) ? .deferZeroBounds : nil
    }

    /// Post-attach decision for the active-zone and cleared-zone branches.
    ///
    /// The witness has already passed the defer gate, mutated its stored zone
    /// state, and (for `hasZone`) attached the overlay and measured
    /// `targetFrame`/`currentFrame` in the container's coordinate space. Frames
    /// are ignored when `hasZone` is `false`.
    ///
    /// - `hasZone`: whether a drop zone is now active.
    /// - `isHidden`: the overlay's live `isHidden`.
    /// - `zoneChanged`: whether the active zone differs from the previous zone.
    /// - `targetFrame`: the measured destination frame for the active zone.
    /// - `currentFrame`: the overlay's live frame.
    public static func transition(
        hasZone: Bool,
        isHidden: Bool,
        zoneChanged: Bool,
        targetFrame: CGRect,
        currentFrame: CGRect
    ) -> DropZoneOverlayTransition {
        guard hasZone else {
            return isHidden ? .noop : .hide
        }

        let needsFrameUpdate = !TerminalSurfaceGeometry.approxEqual(
            currentFrame,
            targetFrame,
            epsilon: 0.5
        )
        let isSameState = !isHidden && !needsFrameUpdate && !zoneChanged
        if isSameState {
            return .noop
        }
        if isHidden {
            return .show(frame: targetFrame)
        }
        return needsFrameUpdate ? .updateFrame(frame: targetFrame) : .raiseAlphaOnly
    }
}

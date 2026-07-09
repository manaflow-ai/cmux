public import CoreGraphics

/// The pure outcome of a drop-zone overlay update on a terminal surface.
///
/// `GhosttyNSView.setDropZoneOverlay(zone:)` resolves its live AppKit state
/// (overlay `isHidden`, the measured target/current frames, whether the
/// requested zone changed) into one of these cases via
/// `TerminalDropZoneOverlayTransitionPlanner`, then runs the matching
/// `NSAnimationContext` sequence app-side. Keeping the branch selection here as
/// a deterministic value makes the transition testable without driving the
/// AppKit drag pipeline.
public enum DropZoneOverlayTransition: Sendable, Equatable {
    /// A zone was requested while the surface bounds are degenerate (≤ 2pt on an
    /// axis); the witness stashes the zone as pending and returns without
    /// touching the overlay.
    case deferZeroBounds
    /// The overlay is hidden and should fade in at `frame`.
    case show(frame: CGRect)
    /// The overlay is visible and should animate its frame to `frame` (raising
    /// alpha to 1 in the same group if it is below 1).
    case updateFrame(frame: CGRect)
    /// The overlay is visible at the right frame for the right zone but its
    /// alpha is below 1; only the alpha needs raising.
    case raiseAlphaOnly
    /// No zone is active and the overlay is visible; it should fade out and hide.
    case hide
    /// Nothing to do: the overlay already matches the requested state, or there
    /// is no zone and the overlay is already hidden.
    case noop
}

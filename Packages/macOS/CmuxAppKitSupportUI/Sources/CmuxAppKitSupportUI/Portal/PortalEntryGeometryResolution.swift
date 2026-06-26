public import CoreGraphics

/// The pure visibility and geometry decision for a hosted portal entry.
///
/// Resolves, from a snapshot of the anchor frame in host coordinates, the host
/// view's bounds, and three injected liveness flags, every boolean and clamped
/// frame the portal frame synchronizer needs to decide whether a hosted view
/// should be shown, hidden, deferred, or recovered this pass. Every input is a
/// value type or a `Bool` that the caller lifted out of live AppKit state
/// (`anchorView.isHiddenOrAncestorHidden`, `hostedView.isHidden`,
/// `entry.visibleInUI`), so the decision is a pure function of its inputs and is
/// fully unit-testable without a window or view hierarchy.
public struct PortalEntryGeometryResolution: Sendable, Equatable {
    /// Whether the host bounds are finite and larger than 1pt on both axes, so
    /// frame math against them is meaningful. The synchronizer defers when false.
    public let hostBoundsReady: Bool
    /// Whether the anchor frame (in host coordinates) has all-finite components.
    public let hasFiniteFrame: Bool
    /// The anchor frame intersected with the host bounds (`.null` when disjoint).
    public let clampedFrame: CGRect
    /// Whether the clamped frame is non-null and larger than 1pt on both axes.
    public let hasVisibleIntersection: Bool
    /// The frame to apply: the clamped frame when the anchor frame is finite and
    /// visibly intersects the host, else the raw anchor frame (so an offscreen
    /// entry still carries a real frame the synchronizer can hide).
    public let targetFrame: CGRect
    /// Whether the target frame is at or below the tiny-hide threshold on either axis.
    public let tinyFrame: Bool
    /// Whether the target frame is large enough to reveal a hidden hosted view.
    public let revealReadyForDisplay: Bool
    /// Whether the anchor frame has no visible intersection with the host bounds.
    public let outsideHostBounds: Bool
    /// Whether the hosted view should be hidden this pass.
    public let shouldHide: Bool
    /// Whether a reveal should be deferred because the hosted view is currently
    /// hidden and the target frame is not yet large enough to display.
    public let shouldDeferReveal: Bool

    /// Resolves the decision from a frame snapshot, the host bounds, and the
    /// injected liveness flags. `tinyHideThreshold`, `minimumRevealWidth`, and
    /// `minimumRevealHeight` are the synchronizer's configured cutoffs.
    public init(
        frameInHost: CGRect,
        hostBounds: CGRect,
        visibleInUI: Bool,
        anchorHidden: Bool,
        hostedViewIsHidden: Bool,
        tinyHideThreshold: CGFloat,
        minimumRevealWidth: CGFloat,
        minimumRevealHeight: CGFloat
    ) {
        let hasFiniteHostBounds = hostBounds.hasFiniteComponents
        self.hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1

        let hasFiniteFrame = frameInHost.hasFiniteComponents
        self.hasFiniteFrame = hasFiniteFrame
        let clampedFrame = frameInHost.intersection(hostBounds)
        self.clampedFrame = clampedFrame
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        self.hasVisibleIntersection = hasVisibleIntersection
        let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost
        self.targetFrame = targetFrame
        let tinyFrame =
            targetFrame.width <= tinyHideThreshold ||
            targetFrame.height <= tinyHideThreshold
        self.tinyFrame = tinyFrame
        let revealReadyForDisplay =
            targetFrame.width >= minimumRevealWidth &&
            targetFrame.height >= minimumRevealHeight
        self.revealReadyForDisplay = revealReadyForDisplay
        let outsideHostBounds = !hasVisibleIntersection
        self.outsideHostBounds = outsideHostBounds
        let shouldHide =
            !visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        self.shouldHide = shouldHide
        self.shouldDeferReveal = !shouldHide && hostedViewIsHidden && !revealReadyForDisplay
    }
}

public import Foundation
public import CmuxBrowser

/// The pure decision/value layer for the hosted Web Inspector dock inside a
/// browser portal host view: the dock metric constants plus the deterministic
/// geometry that derives preferred inspector widths, the manual side-dock
/// threshold, the page/inspector pairing scores, and the divider hit rectangle.
///
/// Every method is a transform of `CGRect`/`CGFloat` inputs into widths,
/// scores, or rectangles. There is no live window, web view, constraint, or
/// tracking-area state here: the AppKit host view (the portal `NSView`) holds
/// all of that, converts its live view bounds to frames, and calls this value
/// for the math. The metrics are stored properties (not a static namespace) so
/// the host owns one configured `HostedInspectorDockLayout` value and queries
/// it; the defaults reproduce the constants the host previously inlined.
public struct HostedInspectorDockLayout {
    /// Half-width the divider hit rectangle is expanded by on each side.
    public let dividerHitExpansion: CGFloat
    /// The smallest width the inspector is allowed to occupy when side docked.
    public let minimumInspectorWidth: CGFloat
    /// The minimum page width that must remain for a manual side dock to be
    /// offered.
    public let minimumInspectorPageWidthForSideDock: CGFloat
    /// The cooldown between adaptive bottom-dock requests.
    public let adaptiveBottomDockRequestCooldown: TimeInterval

    /// Creates a dock layout over the supplied metrics. The defaults reproduce
    /// the constants the portal host view previously inlined.
    public init(
        dividerHitExpansion: CGFloat = 10,
        minimumInspectorWidth: CGFloat = 120,
        minimumInspectorPageWidthForSideDock: CGFloat = 240,
        adaptiveBottomDockRequestCooldown: TimeInterval = 0.25
    ) {
        self.dividerHitExpansion = dividerHitExpansion
        self.minimumInspectorWidth = minimumInspectorWidth
        self.minimumInspectorPageWidthForSideDock = minimumInspectorPageWidthForSideDock
        self.adaptiveBottomDockRequestCooldown = adaptiveBottomDockRequestCooldown
    }

    /// The fraction of `containerBounds.width` that `width` represents, or `nil`
    /// when the container has no positive width.
    public func widthFraction(forWidth width: CGFloat, in containerBounds: CGRect) -> CGFloat? {
        guard containerBounds.width > 0 else { return nil }
        return width / containerBounds.width
    }

    /// The preferred inspector width resolved against `containerBounds`,
    /// preferring the stored fraction (scaled to the current width) and falling
    /// back to the stored absolute width.
    public func resolvedPreferredWidth(
        widthFraction: CGFloat?,
        fallbackWidth: CGFloat?,
        in containerBounds: CGRect
    ) -> CGFloat? {
        if let widthFraction, containerBounds.width > 0 {
            return max(0, containerBounds.width * widthFraction)
        }
        return fallbackWidth
    }

    /// Whether a manual side dock should be offered: there must be at least
    /// `minimumInspectorPageWidthForSideDock` of page width left once the
    /// inspector takes its baseline width. Containers narrower than a hairline
    /// always allow it (the layout has not settled yet).
    public func allowsManualSideDock(containerBounds: CGRect, recordedSideDockWidth: CGFloat?) -> Bool {
        let containerWidth = max(0, containerBounds.width)
        guard containerWidth > 1 else { return true }
        let baselineWidth = max(
            minimumInspectorWidth,
            recordedSideDockWidth ?? minimumInspectorWidth
        )
        return containerWidth - baselineWidth >= minimumInspectorPageWidthForSideDock
    }

    /// The pairing score for a page/inspector frame pair: vertical overlap
    /// dominates, then the combined horizontal coverage, then the page width.
    /// Higher scores are preferred when choosing the divider candidate.
    public func candidateScore(pageFrame: CGRect, inspectorFrame: CGRect) -> CGFloat {
        let overlap = max(0, min(pageFrame.maxY, inspectorFrame.maxY) - max(pageFrame.minY, inspectorFrame.minY))
        let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
        return (overlap * 1_000) + coverageWidth + pageFrame.width
    }

    /// The divider hit-test rectangle for a page/inspector pair docked on
    /// `dockSide`, centered on the divider and widened by `dividerHitExpansion`
    /// on each side.
    public func dividerHitRect(
        in containerBounds: CGRect,
        pageFrame: CGRect,
        inspectorFrame: CGRect,
        dockSide: HostedInspectorDockSide
    ) -> CGRect {
        dockSide.dividerHitRect(
            in: containerBounds,
            pageFrame: pageFrame,
            inspectorFrame: inspectorFrame,
            expansion: dividerHitExpansion
        )
    }
}

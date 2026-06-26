public import Foundation

/// Which side of a hosted browser page the inspector panel docks to, plus the
/// pure geometry that positions the page, the inspector, and the draggable
/// divider between them.
///
/// All members operate on `NSRect`/`CGFloat` values only: there is no live
/// window, web view, or model state involved, so the type is a plain value
/// enum and every method is a deterministic transform of its inputs.
///
/// - `leading`: the inspector docks to the left of the page; the divider sits
///   at the inspector's trailing edge.
/// - `trailing`: the inspector docks to the right of the page; the divider sits
///   at the inspector's leading edge.
public enum HostedInspectorDockSide {
    case leading
    case trailing

    /// Infers the dock side from the relative horizontal placement of the page
    /// and inspector frames, returning `nil` when the two frames overlap rather
    /// than sit cleanly side by side.
    ///
    /// - Parameters:
    ///   - pageFrame: the page view's frame.
    ///   - inspectorFrame: the inspector view's frame.
    ///   - epsilon: a tolerance applied to the adjacency comparison so a
    ///     sub-pixel gap or overlap still resolves to a side.
    public static func resolve(
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        epsilon: CGFloat = 1
    ) -> Self? {
        if pageFrame.maxX <= inspectorFrame.minX + epsilon {
            return .trailing
        }
        if inspectorFrame.maxX <= pageFrame.minX + epsilon {
            return .leading
        }
        return nil
    }

    /// The x coordinate of the divider between the page and the inspector for
    /// this dock side.
    public func dividerX(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return inspectorFrame.maxX
        case .trailing:
            return inspectorFrame.minX
        }
    }

    /// The hit-testing rectangle for the divider, centered on `dividerX` and
    /// widened by `expansion` on each side, spanning the height of `bounds`.
    public func dividerHitRect(
        in bounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        expansion: CGFloat
    ) -> NSRect {
        return NSRect(
            x: dividerX(pageFrame: pageFrame, inspectorFrame: inspectorFrame) - expansion,
            y: bounds.minY,
            width: expansion * 2,
            height: max(0, bounds.height)
        )
    }

    /// Clamps a proposed divider x to keep the inspector at least
    /// `minimumInspectorWidth` wide while staying inside `containerBounds` and
    /// not crossing the page's far edge.
    public func clampedDividerX(
        _ proposedDividerX: CGFloat,
        containerBounds: NSRect,
        pageFrame: NSRect,
        minimumInspectorWidth: CGFloat
    ) -> CGFloat {
        switch self {
        case .leading:
            let minDividerX = min(containerBounds.maxX, containerBounds.minX + minimumInspectorWidth)
            let maxDividerX = max(minDividerX, min(containerBounds.maxX, pageFrame.maxX))
            return max(minDividerX, min(maxDividerX, proposedDividerX))
        case .trailing:
            let minDividerX = max(containerBounds.minX, pageFrame.minX)
            let maxDividerX = max(minDividerX, containerBounds.maxX - minimumInspectorWidth)
            return max(minDividerX, min(maxDividerX, proposedDividerX))
        }
    }

    /// The inspector width implied by a divider x within `containerBounds`,
    /// floored at zero.
    public func inspectorWidth(forDividerX dividerX: CGFloat, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return max(0, dividerX - containerBounds.minX)
        case .trailing:
            return max(0, containerBounds.maxX - dividerX)
        }
    }

    /// Lays out the page and inspector frames for a requested inspector width,
    /// clamping the width to `[minimumInspectorWidth, containerBounds.width]`
    /// and normalizing both frames to the container's vertical extent.
    public func resizedFrames(
        preferredWidth: CGFloat,
        in containerBounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        minimumInspectorWidth: CGFloat
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        let normalizedMinY = containerBounds.minY
        let normalizedHeight = max(0, containerBounds.height)

        switch self {
        case .leading:
            let maximumInspectorWidth = max(0, containerBounds.width)
            let clampedMinimumInspectorWidth = min(maximumInspectorWidth, max(0, minimumInspectorWidth))
            let clampedInspectorWidth = min(
                maximumInspectorWidth,
                max(clampedMinimumInspectorWidth, preferredWidth)
            )
            let dividerX = min(containerBounds.maxX, containerBounds.minX + clampedInspectorWidth)

            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = dividerX
            nextPageFrame.origin.y = normalizedMinY
            nextPageFrame.size.width = max(0, containerBounds.maxX - dividerX)
            nextPageFrame.size.height = normalizedHeight

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = containerBounds.minX
            nextInspectorFrame.origin.y = normalizedMinY
            nextInspectorFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextInspectorFrame.size.height = normalizedHeight
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)

        case .trailing:
            let maximumInspectorWidth = max(0, containerBounds.width)
            let clampedMinimumInspectorWidth = min(maximumInspectorWidth, max(0, minimumInspectorWidth))
            let clampedInspectorWidth = min(
                maximumInspectorWidth,
                max(clampedMinimumInspectorWidth, preferredWidth)
            )
            let dividerX = max(containerBounds.minX, containerBounds.maxX - clampedInspectorWidth)

            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = containerBounds.minX
            nextPageFrame.origin.y = normalizedMinY
            nextPageFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextPageFrame.size.height = normalizedHeight

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = dividerX
            nextInspectorFrame.origin.y = normalizedMinY
            nextInspectorFrame.size.width = max(0, containerBounds.maxX - dividerX)
            nextInspectorFrame.size.height = normalizedHeight
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)
        }
    }
}

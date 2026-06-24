public import CoreGraphics
public import Foundation

/// Which edge of the browser page the hosted inspector docks against, plus the
/// pure geometry for the draggable divider that separates the page from the
/// inspector.
///
/// Every method is a pure transform over `NSRect`/`CGFloat` values: it derives
/// the divider position, hit region, clamp bounds, inspector width, and the
/// resized page/inspector frames for a proposed inspector width. There is no
/// app state, no AppKit view reach, and no I/O, so the type lives in the browser
/// UI package and is exercised by both the window host view and the panel view.
public enum HostedInspectorDockSide {
    /// The inspector sits on the leading (left) edge; the page is to its right.
    case leading
    /// The inspector sits on the trailing (right) edge; the page is to its left.
    case trailing

    /// Infers the dock side from the relative horizontal placement of the page
    /// and inspector frames, or `nil` when they overlap beyond `epsilon`.
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

    /// The x coordinate of the divider edge between the page and inspector.
    public func dividerX(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return inspectorFrame.maxX
        case .trailing:
            return inspectorFrame.minX
        }
    }

    /// The hit-test rectangle for the divider, widened by `expansion` on each
    /// side, spanning the full height of `bounds`.
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

    /// Clamps a proposed divider x to the legal range for this dock side, given
    /// the container bounds, the page frame, and the minimum inspector width.
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

    /// The inspector width implied by a divider x within the container bounds.
    public func inspectorWidth(forDividerX dividerX: CGFloat, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return max(0, dividerX - containerBounds.minX)
        case .trailing:
            return max(0, containerBounds.maxX - dividerX)
        }
    }

    /// The page and inspector frames produced by laying out the inspector at
    /// `preferredWidth` (clamped to `[minimumInspectorWidth, container width]`)
    /// within `containerBounds`.
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

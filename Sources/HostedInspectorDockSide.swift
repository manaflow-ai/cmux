import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


enum HostedInspectorDockSide {
    case leading
    case trailing

    static func resolve(
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

    func dividerX(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return inspectorFrame.maxX
        case .trailing:
            return inspectorFrame.minX
        }
    }

    func dividerHitRect(
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

    func clampedDividerX(
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

    func inspectorWidth(forDividerX dividerX: CGFloat, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return max(0, dividerX - containerBounds.minX)
        case .trailing:
            return max(0, containerBounds.maxX - dividerX)
        }
    }

    func resizedFrames(
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


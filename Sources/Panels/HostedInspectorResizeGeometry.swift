import AppKit

struct HostedInspectorMinimumSizePolicy: Equatable {
    let minimumInspectorExtent: CGFloat
    let minimumPageExtent: CGFloat

    static let sideDock = HostedInspectorMinimumSizePolicy(
        minimumInspectorExtent: 120,
        minimumPageExtent: 120
    )

    static let bottomDock = HostedInspectorMinimumSizePolicy(
        minimumInspectorExtent: 100,
        minimumPageExtent: 80
    )

    init(minimumInspectorExtent: CGFloat, minimumPageExtent: CGFloat) {
        self.minimumInspectorExtent = max(0, minimumInspectorExtent)
        self.minimumPageExtent = max(0, minimumPageExtent)
    }

    init(dockSide: HostedInspectorDockSide) {
        self = dockSide == .bottom ? .bottomDock : .sideDock
    }

    func clampedInspectorExtent(_ proposedExtent: CGFloat, containerExtent: CGFloat) -> CGFloat {
        let extent = max(0, containerExtent)
        let effectiveMinInspector = min(minimumInspectorExtent, extent / 2)
        let effectiveMinPage = min(minimumPageExtent, extent / 2)
        let maxInspector = max(effectiveMinInspector, extent - effectiveMinPage)
        return min(maxInspector, max(effectiveMinInspector, proposedExtent))
    }
}

enum HostedInspectorDockSide {
    case leading
    case trailing
    case bottom

    static func resolve(
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        epsilon: CGFloat = 4
    ) -> Self? {
        let verticalOverlap = verticalOverlap(between: pageFrame, and: inspectorFrame)
        let horizontalOverlap = horizontalOverlap(between: pageFrame, and: inspectorFrame)
        if verticalOverlap > 0, pageFrame.maxX <= inspectorFrame.minX + epsilon {
            return .trailing
        }
        if verticalOverlap > 0, inspectorFrame.maxX <= pageFrame.minX + epsilon {
            return .leading
        }
        if horizontalOverlap > 0, inspectorFrame.maxY <= pageFrame.minY + epsilon {
            return .bottom
        }
        return nil
    }

    var isHorizontalDivider: Bool {
        self == .bottom
    }

    func dividerPosition(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return inspectorFrame.maxX
        case .trailing:
            return inspectorFrame.minX
        case .bottom:
            return inspectorFrame.maxY
        }
    }

    func dividerHitRect(
        in bounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        expansion: CGFloat
    ) -> NSRect {
        let position = dividerPosition(pageFrame: pageFrame, inspectorFrame: inspectorFrame)
        switch self {
        case .leading, .trailing:
            return NSRect(
                x: position - expansion,
                y: bounds.minY,
                width: expansion * 2,
                height: max(0, bounds.height)
            )
        case .bottom:
            return NSRect(
                x: bounds.minX,
                y: position - expansion,
                width: max(0, bounds.width),
                height: expansion * 2
            )
        }
    }

    func clampedDividerPosition(
        _ proposedDividerPosition: CGFloat,
        containerBounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        policy: HostedInspectorMinimumSizePolicy
    ) -> CGFloat {
        let proposedExtent = inspectorExtent(
            forDividerPosition: proposedDividerPosition,
            in: containerBounds
        )
        let clampedExtent = policy.clampedInspectorExtent(
            proposedExtent,
            containerExtent: containerExtent(in: containerBounds)
        )
        return dividerPosition(forInspectorExtent: clampedExtent, in: containerBounds)
    }

    func inspectorExtent(forDividerPosition dividerPosition: CGFloat, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return max(0, dividerPosition - containerBounds.minX)
        case .trailing:
            return max(0, containerBounds.maxX - dividerPosition)
        case .bottom:
            return max(0, dividerPosition - containerBounds.minY)
        }
    }

    func inspectorExtent(inspectorFrame: NSRect, in containerBounds: NSRect) -> CGFloat {
        switch self {
        case .leading, .trailing:
            return min(max(0, containerBounds.width), max(0, inspectorFrame.width))
        case .bottom:
            return min(max(0, containerBounds.height), max(0, inspectorFrame.height))
        }
    }

    func resizedFrames(
        preferredExtent: CGFloat,
        in containerBounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        policy: HostedInspectorMinimumSizePolicy
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        let clampedExtent = policy.clampedInspectorExtent(
            preferredExtent,
            containerExtent: containerExtent(in: containerBounds)
        )
        let dividerPosition = dividerPosition(forInspectorExtent: clampedExtent, in: containerBounds)
        switch self {
        case .leading:
            return horizontalFrames(
                dividerX: dividerPosition,
                containerBounds: containerBounds,
                pageFrame: pageFrame,
                inspectorFrame: inspectorFrame,
                inspectorOnLeadingEdge: true
            )
        case .trailing:
            return horizontalFrames(
                dividerX: dividerPosition,
                containerBounds: containerBounds,
                pageFrame: pageFrame,
                inspectorFrame: inspectorFrame,
                inspectorOnLeadingEdge: false
            )
        case .bottom:
            var nextPageFrame = pageFrame
            nextPageFrame.origin.x = containerBounds.minX
            nextPageFrame.origin.y = dividerPosition
            nextPageFrame.size.width = max(0, containerBounds.width)
            nextPageFrame.size.height = max(0, containerBounds.maxY - dividerPosition)

            var nextInspectorFrame = inspectorFrame
            nextInspectorFrame.origin.x = containerBounds.minX
            nextInspectorFrame.origin.y = containerBounds.minY
            nextInspectorFrame.size.width = max(0, containerBounds.width)
            nextInspectorFrame.size.height = max(0, dividerPosition - containerBounds.minY)
            return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)
        }
    }

    func hasSufficientCrossAxisOverlap(
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        containerBounds: NSRect
    ) -> Bool {
        let overlap = crossAxisOverlap(pageFrame: pageFrame, inspectorFrame: inspectorFrame)
        let containerCrossExtent = isHorizontalDivider ? containerBounds.width : containerBounds.height
        return overlap > min(8, max(0, containerCrossExtent) * 0.25)
    }

    func crossAxisOverlap(pageFrame: NSRect, inspectorFrame: NSRect) -> CGFloat {
        switch self {
        case .leading, .trailing:
            return Self.verticalOverlap(between: pageFrame, and: inspectorFrame)
        case .bottom:
            return Self.horizontalOverlap(between: pageFrame, and: inspectorFrame)
        }
    }

    func pageExtent(pageFrame: NSRect) -> CGFloat {
        switch self {
        case .leading, .trailing:
            return max(0, pageFrame.width)
        case .bottom:
            return max(0, pageFrame.height)
        }
    }

    private func containerExtent(in bounds: NSRect) -> CGFloat {
        isHorizontalDivider ? bounds.height : bounds.width
    }

    private func dividerPosition(forInspectorExtent inspectorExtent: CGFloat, in bounds: NSRect) -> CGFloat {
        switch self {
        case .leading:
            return bounds.minX + inspectorExtent
        case .trailing:
            return bounds.maxX - inspectorExtent
        case .bottom:
            return bounds.minY + inspectorExtent
        }
    }

    private func horizontalFrames(
        dividerX: CGFloat,
        containerBounds: NSRect,
        pageFrame: NSRect,
        inspectorFrame: NSRect,
        inspectorOnLeadingEdge: Bool
    ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
        var nextPageFrame = pageFrame
        var nextInspectorFrame = inspectorFrame
        nextPageFrame.origin.y = containerBounds.minY
        nextPageFrame.size.height = max(0, containerBounds.height)
        nextInspectorFrame.origin.y = containerBounds.minY
        nextInspectorFrame.size.height = max(0, containerBounds.height)

        if inspectorOnLeadingEdge {
            nextInspectorFrame.origin.x = containerBounds.minX
            nextInspectorFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextPageFrame.origin.x = dividerX
            nextPageFrame.size.width = max(0, containerBounds.maxX - dividerX)
        } else {
            nextPageFrame.origin.x = containerBounds.minX
            nextPageFrame.size.width = max(0, dividerX - containerBounds.minX)
            nextInspectorFrame.origin.x = dividerX
            nextInspectorFrame.size.width = max(0, containerBounds.maxX - dividerX)
        }
        return (pageFrame: nextPageFrame, inspectorFrame: nextInspectorFrame)
    }

    private static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func horizontalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }
}

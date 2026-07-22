import AppKit

@MainActor
struct SidebarResizerOcclusionResolver {
    var topmostMouseEventWindowNumber: (NSPoint) -> Int? = { screenPoint in
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
    }

    func dividerBandContains(
        point: NSPoint,
        contentBounds: NSRect,
        isLeftSidebarVisible: Bool,
        leftDividerX: CGFloat,
        isRightSidebarVisible: Bool,
        rightDividerX: CGFloat
    ) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if isLeftSidebarVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: leftDividerX).contains(point.x) {
            return true
        }
        return isRightSidebarVisible &&
            SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightDividerX).contains(point.x)
    }

    func bandMayActivate(
        isDragging: Bool,
        isInDividerBand: Bool,
        screenPoint: NSPoint,
        observedWindowNumber: Int
    ) -> Bool {
        guard !isDragging else { return true }
        guard isInDividerBand else { return false }
        return topmostMouseEventWindowNumber(screenPoint) == observedWindowNumber
    }
}

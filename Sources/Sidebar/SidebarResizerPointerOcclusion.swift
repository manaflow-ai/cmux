import AppKit

enum SidebarResizerOcclusionPolicy {
    static func bandMayActivate(
        isDragging: Bool,
        isInDividerBand: Bool,
        pointerWindowNumber: Int?,
        observedWindowNumber: Int
    ) -> Bool {
        if isDragging {
            return true
        }
        return isInDividerBand && pointerWindowNumber == observedWindowNumber
    }
}

@MainActor
enum SidebarResizerPointerOcclusion {
    static func dividerBandContains(
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

    static func topmostMouseEventWindowNumber(at screenPoint: NSPoint) -> Int? {
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
    }

    static func bandMayActivate(
        isDragging: Bool,
        isInDividerBand: Bool,
        screenPoint: NSPoint,
        observedWindowNumber: Int
    ) -> Bool {
        guard !isDragging else { return true }
        guard isInDividerBand else { return false }
        return SidebarResizerOcclusionPolicy.bandMayActivate(
            isDragging: false,
            isInDividerBand: true,
            pointerWindowNumber: topmostMouseEventWindowNumber(at: screenPoint),
            observedWindowNumber: observedWindowNumber
        )
    }
}

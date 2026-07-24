import AppKit

enum WorkspaceFloatingDockStashLayout {
    static let restingVisibleFraction: CGFloat = 0.5
    static let hoverRevealDistance: CGFloat = 96

    static func stashedWindowFrame(
        windowFrame: CGRect,
        visibleScreenFrame: CGRect,
        isHovered: Bool
    ) -> CGRect {
        let restingVisibleWidth = windowFrame.width * restingVisibleFraction
        let visibleWidth = min(
            windowFrame.width,
            restingVisibleWidth + (isHovered ? hoverRevealDistance : 0)
        )
        let y: CGFloat
        if windowFrame.height >= visibleScreenFrame.height {
            y = visibleScreenFrame.minY
        } else {
            y = min(
                max(windowFrame.minY, visibleScreenFrame.minY),
                visibleScreenFrame.maxY - windowFrame.height
            )
        }
        return CGRect(
            x: visibleScreenFrame.maxX - visibleWidth,
            y: y,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }
}

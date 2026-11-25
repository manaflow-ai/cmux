import CoreGraphics
import CmuxNextTabs

let metrics = TabStripMetrics.standard
let roomyWidth = max(metrics.faviconCloseWidth, metrics.contentLeadingInset + metrics.contentTrailingInset + metrics.closeMinContentsWidth) + 80

for style in [TabStripStyle.chrome, .compact] {
    let active = TabChromeVisibility.resolve(
        width: roomyWidth, isPinned: false, isSelected: true, isHovered: false,
        style: style, metrics: metrics)
    let inactive = TabChromeVisibility.resolve(
        width: roomyWidth, isPinned: false, isSelected: false, isHovered: false,
        style: style, metrics: metrics)
    let hovered = TabChromeVisibility.resolve(
        width: roomyWidth, isPinned: false, isSelected: false, isHovered: true,
        style: style, metrics: metrics)
    precondition(active.showsClose, "active \(style) tab must show close at rest")
    precondition(!inactive.showsClose, "inactive \(style) tab must hide close at rest")
    precondition(hovered.showsClose, "hovered \(style) tab must show close")

    let activeWithStatus = TabChromeVisibility.resolve(
        width: roomyWidth, isPinned: false, isSelected: true, isHovered: false,
        hasStatus: true, style: style, metrics: metrics)
    let hoveredActiveWithStatus = TabChromeVisibility.resolve(
        width: roomyWidth, isPinned: false, isSelected: true, isHovered: true,
        hasStatus: true, style: style, metrics: metrics)
    precondition(activeWithStatus == hoveredActiveWithStatus,
                 "hover must not relayout an active \(style) tab")
}

let hitRect = metrics.closeHitRect(CGRect(x: 0, y: 0, width: metrics.closeButtonSize, height: metrics.closeButtonSize))
precondition(hitRect.width >= 20 && hitRect.height >= 20, "close hit target must be at least 20 points")

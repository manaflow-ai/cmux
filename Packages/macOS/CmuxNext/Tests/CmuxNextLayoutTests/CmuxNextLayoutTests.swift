import CoreGraphics
import Testing
import CmuxNextDesign
@testable import CmuxNextLayout

private func style(gap: CGFloat = 8) -> LayoutStyle {
    var style = LayoutStyle()
    style.columnGap = gap
    style.dividerThickness = 1
    style.dividerHitThickness = 9
    style.paneChromeHeight = 0
    style.minimumPaneContentSize = CGSize(width: 20, height: 20)
    return style
}


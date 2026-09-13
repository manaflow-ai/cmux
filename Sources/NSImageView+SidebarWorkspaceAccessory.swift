import AppKit
import SwiftUI

extension NSImageView {
    /// Applies the shared secondary treatment for workspace identity accessories.
    func configureSidebarWorkspaceAccessory(
        symbol: String,
        label: String?,
        pointSize: CGFloat,
        tint: NSColor,
        weight: Font.Weight = .semibold
    ) {
        guard let label else {
            image = nil
            toolTip = nil
            isHidden = true
            return
        }
        let renderedImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: symbol, pointSize: pointSize, weight: weight
        )
        image = renderedImage
        isHidden = renderedImage == nil
        guard renderedImage != nil else { return }
        toolTip = label
        contentTintColor = tint
    }

    /// Reserves one fixed accessory slot without changing the row's vertical layout.
    func layoutSidebarWorkspaceAccessory(
        maxX: CGFloat, centerY: CGFloat, side: CGFloat, spacing: CGFloat, apply: Bool
    ) -> CGFloat {
        guard !isHidden else { return maxX }
        if apply {
            frame = NSRect(x: maxX - side, y: centerY - side / 2, width: side, height: side)
        }
        return maxX - side - spacing
    }

}

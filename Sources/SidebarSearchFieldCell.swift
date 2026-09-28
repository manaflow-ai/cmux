import AppKit
import SwiftUI

/// Shared bezel and icon alignment; AppKit owns text editing and button handling.
@MainActor
final class SidebarSearchFieldCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        SidebarSearchField.alignedSearchButtonRect(super.searchButtonRect(forBounds: rect), in: rect)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        SidebarSearchField.alignedSearchTextRect(super.searchTextRect(forBounds: rect), in: rect)
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.06).cgColor)
            context.addPath(RoundedRectangle(
                cornerRadius: RightSidebarChromeMetrics.controlCornerRadius,
                style: .continuous
            ).path(in: frame).cgPath)
            context.fillPath()
            context.restoreGState()
        }
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

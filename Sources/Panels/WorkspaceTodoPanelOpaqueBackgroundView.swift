import AppKit
import CmuxSettings

final class WorkspaceTodoPanelOpaqueBackgroundView: NSView {
    var color = ChromeColor(red: 1, green: 1, blue: 1)
    override var isOpaque: Bool { color.alpha >= 0.999 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        ).setFill()
        dirtyRect.fill()
    }
}

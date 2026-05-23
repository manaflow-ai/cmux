import AppKit

@MainActor
enum GlobalHotkeyPanelLayout {
    static func panelFrame(in screenFrame: NSRect) -> NSRect {
        let margin = max(20, min(56, screenFrame.height * 0.045))
        let width = min(max(960, screenFrame.width * 0.88), screenFrame.width - (margin * 2))
        let height = min(max(560, screenFrame.height * 0.78), screenFrame.height - (margin * 2))
        let origin = NSPoint(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.maxY - height - margin
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
    }

    static func preferredScreen(for point: NSPoint = NSEvent.mouseLocation) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

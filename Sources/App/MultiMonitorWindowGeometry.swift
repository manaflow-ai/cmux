import AppKit

/// Shared multi-monitor window placement geometry used by main windows,
/// settings recovery, and other AppKit presenters that clamp frames onto a
/// connected display.
enum MultiMonitorWindowGeometry {
    /// Pure selection of the visible-screen frame a window should be clamped
    /// into. When the window's saved frame is off every active screen (e.g.
    /// restored onto a now-disconnected display) it recovers onto the screen
    /// under the cursor, then the main/first screen. Cursor hit-testing uses
    /// each screen's *full* frame: `visibleFrame` excludes the menu bar and
    /// Dock strips, and the cursor sits exactly there when a window is opened
    /// from the menu bar, which would misroute recovery to the main screen.
    static func targetVisibleFrame(
        windowFrame: NSRect,
        screens: [(frame: NSRect, visibleFrame: NSRect)],
        mouseLocation: NSPoint?,
        fallbackVisibleFrame: NSRect?
    ) -> NSRect? {
        guard !screens.isEmpty else { return fallbackVisibleFrame }

        // Prefer the screen the window already overlaps the most so a window
        // that is mostly visible stays where the user put it.
        var bestFrame: NSRect?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = screen.visibleFrame.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestFrame = screen.visibleFrame
            }
        }
        if let bestFrame, bestArea > 0 {
            return bestFrame
        }

        // The window is off every active screen. Recover onto the screen under
        // the cursor when possible so the window appears where the user is looking.
        if let mouseLocation,
           let mouseScreen = screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen.visibleFrame
        }
        return fallbackVisibleFrame ?? screens.first?.visibleFrame
    }

    /// Pure clamp geometry: fit `frame` within `visibleFrame` (honoring `inset`
    /// and a minimum size).
    static func clampedFrame(
        _ frame: NSRect,
        minimumSize: NSSize,
        into visibleFrame: NSRect,
        inset: CGFloat
    ) -> NSRect {
        var result = frame
        let maxVisibleSize = NSSize(
            width: max(minimumSize.width, visibleFrame.width - 2 * inset),
            height: max(minimumSize.height, visibleFrame.height - 2 * inset)
        )
        result.size.width = min(result.size.width, maxVisibleSize.width)
        result.size.height = min(result.size.height, maxVisibleSize.height)
        let minX = visibleFrame.minX + inset
        let minY = visibleFrame.minY + inset
        let maxX = max(minX, visibleFrame.maxX - inset - result.width)
        let maxY = max(minY, visibleFrame.maxY - inset - result.height)
        result.origin = NSPoint(
            x: min(max(result.origin.x, minX), maxX),
            y: min(max(result.origin.y, minY), maxY)
        )
        return result
    }

    /// Clamp `frame` onto a connected display using the shared target-screen
    /// selection and clamp geometry. Returns `nil` when no screen is available.
    static func recoveredFrame(
        _ frame: NSRect,
        minimumSize: NSSize,
        screens: [(frame: NSRect, visibleFrame: NSRect)],
        mouseLocation: NSPoint?,
        fallbackVisibleFrame: NSRect?,
        inset: CGFloat
    ) -> NSRect? {
        guard let targetVisibleFrame = targetVisibleFrame(
            windowFrame: frame,
            screens: screens,
            mouseLocation: mouseLocation,
            fallbackVisibleFrame: fallbackVisibleFrame
        ) else { return nil }
        return clampedFrame(
            frame,
            minimumSize: minimumSize,
            into: targetVisibleFrame,
            inset: inset
        )
    }
}
import AppKit

/// Pure multi-monitor recovery geometry and window-usability policy for the
/// Settings window, split out of `SettingsWindowPresenter` (which stays under
/// the Swift file-length budget) and kept as extensions so call sites and
/// tests address one type.
extension SettingsWindowPresenter {
    static let visibleAreaInset: CGFloat = 18

    func clampToVisibleAreaIfNeeded(_ window: NSWindow) {
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let fallbackVisibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        guard let visibleFrame = Self.targetVisibleFrame(
            windowFrame: window.frame,
            screens: screens,
            mouseLocation: NSEvent.mouseLocation,
            fallbackVisibleFrame: fallbackVisibleFrame
        ) else { return }

        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, window.contentMinSize.width),
            height: max(window.minSize.height, window.contentMinSize.height)
        )
        let originalFrame = window.frame
        let clamped = Self.clampedFrame(
            originalFrame,
            minimumSize: minimumFrameSize,
            into: visibleFrame,
            inset: Self.visibleAreaInset
        )
        guard clamped != originalFrame else { return }

        let wasOffAllScreens = window.screen == nil
        window.setFrame(clamped, display: true)
        if wasOffAllScreens {
            Self.log.notice(
                """
                settings.window.clamp recovered an offscreen frame onto a visible screen \
                from=\(NSStringFromRect(originalFrame), privacy: .public) \
                to=\(NSStringFromRect(clamped), privacy: .public)
                """
            )
        }
    }

    static func logExistingWindowState(_ window: NSWindow) {
        log.notice(
            """
            settings.window.show found existing window \
            visible=\(window.isVisible, privacy: .public) \
            miniaturized=\(window.isMiniaturized, privacy: .public) \
            onActiveSpace=\(window.isOnActiveSpace, privacy: .public) \
            offAllScreens=\(window.screen == nil, privacy: .public) \
            frame=\(NSStringFromRect(window.frame), privacy: .public)
            """
        )
    }

    /// Diagnostic-grade description of a window that failed to become
    /// visible after ordering front, carried in `.failed` and the logs.
    static func presentationFailureReason(
        window: NSWindow,
        attempt: Int,
        reusedExisting: Bool
    ) -> String {
        """
        window did not become visible after order front \
        (attempt \(attempt)/\(maxPresentAttempts), reusedExisting=\(reusedExisting), \
        appHidden=\(NSApp.isHidden), appActive=\(NSApp.isActive), \
        miniaturized=\(window.isMiniaturized), screens=\(NSScreen.screens.count), \
        frame=\(NSStringFromRect(window.frame)))
        """
    }

    /// Pure usability policy so the self-healing decision is unit-testable.
    static func unusableWindowReason(
        hasContent: Bool,
        frame: NSRect,
        minimumSize: NSSize
    ) -> String? {
        if !hasContent {
            return "window has no content (deallocated or unloaded content view)"
        }
        if frame.width < minimumSize.width / 2 || frame.height < minimumSize.height / 2 {
            return "window frame is degenerate (\(Int(frame.width))x\(Int(frame.height)))"
        }
        return nil
    }

    /// Pure selection of the visible-screen frame the settings window should be
    /// clamped into. When the window's saved frame is off every active screen
    /// (e.g. restored onto a now-disconnected display in a multi-monitor setup)
    /// it recovers onto the screen under the cursor, then the main/first screen.
    /// Cursor hit-testing uses each screen's *full* frame: `visibleFrame`
    /// excludes the menu bar and Dock strips, and the cursor sits exactly there
    /// when Settings is opened from the menu bar, which would misroute the
    /// recovery to the main screen. The returned rect is always a visible
    /// frame. Factored out so multi-monitor recovery is unit-testable.
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
        // the cursor when possible so Settings appears where the user is looking.
        if let mouseLocation,
           let mouseScreen = screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen.visibleFrame
        }
        return fallbackVisibleFrame ?? screens.first?.visibleFrame
    }

    /// Pure clamp geometry: fit `frame` within `visibleFrame` (honoring `inset`
    /// and a minimum size). Factored out of `clampToVisibleAreaIfNeeded` so the
    /// geometry is unit-testable independent of `NSWindow`/`NSScreen`.
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
}

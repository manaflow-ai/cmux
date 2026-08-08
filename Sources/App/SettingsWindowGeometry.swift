import AppKit

/// Settings window recovery and window-usability policy, split out of
/// `SettingsWindowPresenter` so the presenter stays under the Swift
/// file-length budget. Multi-display clamp math lives in
/// `MultiMonitorWindowGeometry` and is shared with main-window recovery.
extension SettingsWindowPresenter {
    static let visibleAreaInset: CGFloat = 18

    func clampToVisibleAreaIfNeeded(_ window: NSWindow) {
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let fallbackVisibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        let originalFrame = window.frame
        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, window.contentMinSize.width),
            height: max(window.minSize.height, window.contentMinSize.height)
        )
        guard let clamped = MultiMonitorWindowGeometry.recoveredFrame(
            originalFrame,
            minimumSize: minimumFrameSize,
            screens: screens,
            mouseLocation: NSEvent.mouseLocation,
            fallbackVisibleFrame: fallbackVisibleFrame,
            inset: Self.visibleAreaInset
        ) else { return }
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
}

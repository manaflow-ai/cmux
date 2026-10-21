import AppKit

/// lawmux: when the system-wide hotkey (Show/Hide All Windows) reveals a
/// window, size it to its screen's visible frame, like the Hammerspoon
/// `win:maximize()` binding this replaces. Native full screen is left alone.
enum LawmuxGlobalHotkeyWindowMaximizer {
    @MainActor
    static func maximize(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let target = screen.visibleFrame
        guard window.frame != target else { return }
        window.setFrame(target, display: true, animate: false)
    }
}

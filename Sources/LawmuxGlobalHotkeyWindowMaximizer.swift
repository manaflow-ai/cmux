import AppKit

/// lawmux: behaviour of the system-wide hotkey (Shift+Space), replacing a
/// Hammerspoon binding. Upstream's toggle hides the app and lets macOS pick
/// the next frontmost app; this instead remembers the app that was frontmost
/// when lawmux was summoned and activates that app again on the next press.
/// On reveal, the window is maximized on the screen under the mouse cursor
/// (the Hammerspoon `win:maximize()` equivalent, but display-aware).
///
/// The file keeps its original name because upstream's wiring tool only adds
/// project entries; renaming would mean editing project.pbxproj by hand.
@MainActor
final class LawmuxGlobalHotkey {
    static let shared = LawmuxGlobalHotkey()

    /// The app that was frontmost when lawmux was last summoned by the hotkey.
    private var previousApp: NSRunningApplication?

    /// - Parameter reveal: Shows lawmux's windows and returns the one made key.
    func toggle(reveal: () -> NSWindow?) {
        let current = NSRunningApplication.current
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == current.processIdentifier {
            returnToPreviousApp(from: current)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        if let window = reveal() {
            Self.maximize(window, on: Self.screenUnderMouse() ?? window.screen ?? NSScreen.main)
        }
    }

    private func returnToPreviousApp(from current: NSRunningApplication) {
        defer { previousApp = nil }
        guard let previous = previousApp,
              !previous.isTerminated,
              previous.processIdentifier != current.processIdentifier
        else {
            NSApp.hide(nil)
            return
        }
        // macOS 14+ only lets the active app hand activation to another one;
        // `activate(from:)` is that cooperative hand-over.
        if !previous.activate(from: current, options: []) {
            NSApp.hide(nil)
        }
    }

    static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    static func maximize(_ window: NSWindow, on screen: NSScreen?) {
        guard !window.styleMask.contains(.fullScreen), let screen else { return }
        let target = screen.visibleFrame
        guard window.frame != target else { return }
        window.setFrame(target, display: true, animate: false)
    }
}

import AppKit
import os

/// lawmux: behaviour of the system-wide hotkey (Shift+Space), replacing a
/// Hammerspoon binding. Upstream's toggle hides the app and lets macOS pick
/// the next frontmost app; this instead remembers the app that was frontmost
/// when lawmux was summoned and activates that app again on the next press.
///
/// The windows are marked `.moveToActiveSpace` before they are revealed, so
/// lawmux appears on the desktop (Space) the user is on instead of switching
/// desktops, and returning stays on that desktop too. On reveal, the window is
/// maximized on the screen under the mouse cursor.
///
/// Decisions are logged under subsystem `com.lawrenceturnerw.lawmux`:
///   log show --predicate 'subsystem == "com.lawrenceturnerw.lawmux"' --last 10m
///
/// The file keeps its original name because upstream's wiring tool only adds
/// project entries; renaming would mean editing project.pbxproj by hand.
@MainActor
final class LawmuxGlobalHotkey {
    static let shared = LawmuxGlobalHotkey()

    private let logger = Logger(subsystem: "com.lawrenceturnerw.lawmux", category: "hotkey")

    /// The app that was frontmost when lawmux was last summoned by the hotkey.
    private var previousApp: NSRunningApplication?

    /// - Parameters:
    ///   - windows: lawmux's main windows, marked to follow the active Space.
    ///   - reveal: Shows those windows and returns the one made key.
    func toggle(windows: [NSWindow], reveal: () -> NSWindow?) {
        // `NSApp.isActive` is immediate; `frontmostApplication` can lag right
        // after a click or a Space transition and misreport a second press.
        if NSApp.isActive {
            returnToPreviousApp()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost
        for window in windows {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
        let screen = Self.screenUnderMouse()
        logger.notice(
            "summon: from=\(frontmost?.bundleIdentifier ?? "nil", privacy: .public) screen=\(screen?.localizedName ?? "nil", privacy: .public) windows=\(windows.count)"
        )
        if let window = reveal() {
            Self.maximize(window, on: screen ?? window.screen ?? NSScreen.main)
        } else {
            logger.notice("summon: nothing revealed")
        }
        // Some apps (Chrome, notably) kept activation after the reveal, so the
        // next press looked like another summon. The hotkey press is a user
        // action, so forcing activation is permitted; upstream uses the same
        // call elsewhere. Activation is asynchronous: log the outcome shortly
        // after instead of checking it here.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [logger] in
            logger.notice("summon: active after 0.5s = \(NSApp.isActive)")
        }
    }

    private func returnToPreviousApp() {
        let previous = previousApp
        previousApp = nil
        let current = NSRunningApplication.current
        guard let previous,
              !previous.isTerminated,
              previous.processIdentifier != current.processIdentifier
        else {
            logger.notice("return: no previous app (\(previous?.bundleIdentifier ?? "nil", privacy: .public)); hiding")
            NSApp.hide(nil)
            return
        }
        // macOS 14+ only lets the active app hand activation to another one;
        // `activate(from:)` is that cooperative hand-over.
        let handedOver = previous.activate(from: current, options: [])
        logger.notice("return: to=\(previous.bundleIdentifier ?? "nil", privacy: .public) activated=\(handedOver)")
        if !handedOver {
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

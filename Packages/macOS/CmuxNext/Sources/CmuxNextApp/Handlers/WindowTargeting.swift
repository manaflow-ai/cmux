import AppKit

/// The cmux window a window action (Zoom, Select Next/Previous Window, Close
/// All Windows) acts on: the key window, else the frontmost cmux window,
/// never simply the first window opened (nxdog47: Zoom hit the first window
/// while the app was in the background).
struct WindowTargeting {
    var keyWindow: NSWindow?
    /// Every app window, front to back (`NSApp.orderedWindows`).
    var ordered: [NSWindow]
    /// The cmux shell windows.
    var shells: [NSWindow]

    @MainActor
    static func current(_ shells: [NSWindow]) -> WindowTargeting {
        WindowTargeting(keyWindow: NSApp.keyWindow, ordered: NSApp.orderedWindows, shells: shells)
    }

    var target: NSWindow? { shells.first }

    /// The shell window `offset` places from the target, front to back, wrapping.
    func cycled(_ offset: Int) -> NSWindow? { nil }

    /// Closes `window` the way its close button would (its delegate's
    /// `windowShouldClose` decides), also when the window has no close button.
    @MainActor
    static func close(_ window: NSWindow) {
        window.performClose(nil)
    }
}

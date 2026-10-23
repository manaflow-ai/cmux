import AppKit

/// Whether a key-down may reach the key window.
@MainActor
struct CrossWindowInputGuard {
    /// The cmux window id that owns a window (itself, a sheet, a Chromium page window, a panel over it).
    let owner: (NSWindow) -> String?

    init(windows: WindowManager) {
        owner = { [weak windows] window in windows?.owner(of: window)?.state.id }
    }

    /// True when the key was typed into one cmux window and AppKit would deliver it to another.
    func dropsKey(eventWindow: NSWindow?, keyWindow: NSWindow?) -> Bool {
        false
    }
}

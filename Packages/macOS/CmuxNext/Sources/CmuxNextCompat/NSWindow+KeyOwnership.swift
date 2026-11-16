public import AppKit

extension NSWindow {
    /// Whether this window may take the key window from `keyWindow` without taking the person's keys from another
    /// window: when no window is key, or when `keyWindow` is this window or one it owns (a child window, such as a
    /// Chromium page window, or a sheet), at any depth.
    ///
    /// - Parameter keyWindow: The app's key window now (`NSApp.keyWindow`), or nil when none is key.
    /// - Returns: True when taking the key window keeps the keys in this window's family.
    public func mayTakeKey(from keyWindow: NSWindow?) -> Bool {
        guard let keyWindow else { return true }
        var current: NSWindow? = keyWindow
        while let candidate = current {
            if candidate === self { return true }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }
}

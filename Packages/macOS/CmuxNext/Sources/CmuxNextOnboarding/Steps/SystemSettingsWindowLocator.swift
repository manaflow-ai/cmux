import AppKit
import CoreGraphics

/// Finds the System Settings window the drag panel docks under.
@MainActor
protocol SystemSettingsWindowLocating {
    /// The front System Settings window's frame in AppKit screen
    /// coordinates, or nil when System Settings shows no window.
    func frame() -> NSRect?
}

/// Reads System Settings' front window from the window server
/// (`CGWindowListCopyWindowInfo`). Bounds and owner need no permission; only
/// window titles would need Screen Recording, and this never reads them. It
/// lists no processes: each on-screen window's owner is looked up by its pid.
struct SystemSettingsWindowLocator: SystemSettingsWindowLocating {
    /// System Settings (macOS 13 and later keeps the old bundle identifier).
    static let bundleIdentifier = "com.apple.systempreferences"

    func frame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return nil }
        return Self.frame(in: list, primaryHeight: primary.height) { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Self.bundleIdentifier
        }
    }

    /// The first (front-most) normal-level window of an owner `isSettings` accepts in a window
    /// server list, big enough to be a settings window (not a sheet's
    /// shadow or a tooltip), converted from the window server's top-left
    /// origin to AppKit's bottom-left one (`primaryHeight`: the height of
    /// the screen with the menu bar).
    static func frame(in list: [[String: Any]], primaryHeight: CGFloat, isSettings: (pid_t) -> Bool) -> NSRect? {
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int,
                  (info[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 200, rect.height >= 200, isSettings(pid_t(owner)) else { continue }
            return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

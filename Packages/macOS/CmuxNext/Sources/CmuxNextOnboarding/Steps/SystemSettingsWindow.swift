import AppKit

/// Where the System Settings window is, so the drag panel can dock over
/// its bottom. The window list read runs off the main thread; it needs no
/// grant (owner and bounds are public, only titles are not).
nonisolated struct SystemSettingsWindow {
    static let bundleID = "com.apple.systempreferences"
    /// Room kept between the panel and the window's bottom and right edges.
    static let inset: CGFloat = 16
    /// About the width of System Settings' sidebar: the panel stays right
    /// of it, over the list it points to, when the window is wide enough.
    static let sidebarWidth: CGFloat = 220

    /// The frontmost System Settings window's frame in AppKit screen
    /// coordinates, or nil when none is on screen.
    @MainActor static func frontFrame() async -> NSRect? {
        guard let bounds = await windowBounds(), let primary = NSScreen.screens.first else { return nil }
        return appKitFrame(bounds, primaryHeight: primary.frame.height)
    }

    @concurrent static func windowBounds() async -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return pick(list, owners: ownerNames())
    }

    /// The names System Settings' windows carry as their owner: the app's
    /// name in this Mac's language (from its bundle, no process lookup),
    /// and the English names of macOS 13 and later and of older releases.
    static func ownerNames() -> Set<String> {
        var names: Set<String> = ["System Settings", "System Preferences"]
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            names.insert(name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        }
        return names
    }

    /// The first (frontmost) normal-level window owned by one of `owners`
    /// and big enough to be the main window, from a
    /// `CGWindowListCopyWindowInfo` list.
    static func pick(_ list: [[String: Any]], owners: Set<String>) -> CGRect? {
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String, owners.contains(owner),
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 300, bounds.height >= 300 else { continue }
            return bounds
        }
        return nil
    }

    /// Window list bounds have a top-left origin on the primary screen;
    /// AppKit frames have a bottom-left one.
    static func appKitFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// The panel's frame docked over the bottom of `settings`: right of the
    /// sidebar when it fits, else centered, and inside `visible`.
    static func dockedFrame(panel size: NSSize, settings: NSRect, visible: NSRect?) -> NSRect {
        var x = settings.maxX - inset - size.width
        if x < settings.minX + sidebarWidth { x = settings.midX - size.width / 2 }
        var frame = NSRect(x: x, y: settings.minY + inset, width: size.width, height: size.height)
        if let visible {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        return frame
    }

    /// Bottom center of `visible`, clear of the Dock: where the panel waits
    /// when no System Settings window is on screen.
    static func fallbackFrame(panel size: NSSize, visible: NSRect) -> NSRect {
        NSRect(x: visible.midX - size.width / 2, y: visible.minY + 48, width: size.width, height: size.height)
    }
}

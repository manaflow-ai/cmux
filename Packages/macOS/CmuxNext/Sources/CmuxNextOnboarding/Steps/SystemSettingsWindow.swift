import AppKit

/// A System Settings window found in the window list: its number, its
/// window-list bounds (top-left origin on the primary screen) and its owner's pid.
nonisolated struct SettingsWindowMatch: Equatable, Sendable {
    let id: CGWindowID
    let bounds: CGRect
    /// System Settings' pid (0 when the list gave none): the AX read of its first list needs it.
    var pid: pid_t = 0
}

/// One read of the System Settings window the drag panel follows.
nonisolated enum SettingsWindowState: Equatable, Sendable {
    /// On screen, at these window-list bounds.
    case onScreen(CGRect)
    /// Still open but not on screen: minimized, hidden, or on another Space.
    case offScreen
    /// Closed, or System Settings quit.
    case gone
}

/// Where the System Settings window is, so the drag panel can dock over it
/// (under the first list of the Screenshots pane, over the bottom of the
/// Accessibility pane). The window list reads run off the main thread; they need no
/// grant (owner and bounds are public, only titles are not).
nonisolated struct SystemSettingsWindow {
    static let bundleID = "com.apple.systempreferences"
    /// Room kept between the panel and the window's bottom edge.
    static let inset: CGFloat = 16
    /// The app list of a Privacy & Security pane, from the window's left edge, in points.
    /// Measured on macOS 26.6 (System Settings is 723 pt wide and cannot be resized) in
    /// 2x captures of the Screen & System Audio Recording and the Accessibility panes;
    /// both panes give the same numbers. The list's rows start here...
    static let listLeading: CGFloat = 243
    /// ...and end here (20 pt in from the window's right edge)...
    static let listTrailing: CGFloat = 703
    /// ...and the center of their app icons is here (each icon 20 pt, 10 pt in from the row's edge).
    static let listIconCenter: CGFloat = 263
    static var listWidth: CGFloat { listTrailing - listLeading }
    /// The window's toolbar: the panel never docks over it.
    static let toolbarHeight: CGFloat = 52
    /// Room between the bottom of the pane's first list and the panel's top.
    static let listGap: CGFloat = 8
    // Measured on macOS 26.6 (AX frames of the Screen & System Audio Recording pane): the list
    // starts 111.5 pt under the window's top, each row is 40 pt and its +/- buttons add 24 pt, so its
    // length depends on how many apps it holds. With no read of it (``SystemSettingsList``), the panel
    // docks at the window's bottom like the Accessibility panel: a guess would cover the list's rows.

    /// The frontmost System Settings window on screen, or nil when there is none.
    @concurrent static func frontWindow() async -> SettingsWindowMatch? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return pick(list, owners: ownerNames())
    }

    /// The window `id` now. One window's entry only: about 70 us a read (p50, p99
    /// 0.23 ms; the full on-screen list is about 0.46 ms), measured on macOS 26.6.
    @concurrent static func state(of id: CGWindowID) async -> SettingsWindowState {
        state(from: CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? [])
    }

    /// The state in a `.optionIncludingWindow` list: no entry once the window closed,
    /// no on-screen mark while it is minimized, hidden or on another Space.
    static func state(from list: [[String: Any]]) -> SettingsWindowState {
        guard let info = list.first else { return .gone }
        guard info[kCGWindowIsOnscreen as String] as? Bool == true,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return .offScreen }
        return .onScreen(bounds)
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
    static func pick(_ list: [[String: Any]], owners: Set<String>) -> SettingsWindowMatch? {
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String, owners.contains(owner),
                  info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 300, bounds.height >= 300 else { continue }
            let pid = (info[kCGWindowOwnerPID as String] as? Int).map { pid_t(truncatingIfNeeded: $0) } ?? 0
            return SettingsWindowMatch(id: CGWindowID(number), bounds: bounds, pid: pid)
        }
        return nil
    }

    /// Window list bounds have a top-left origin on the primary screen;
    /// AppKit frames have a bottom-left one.
    static func appKitFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// The panel's frame docked to `settings`, its helper icon (`iconCenter` from the panel's left
    /// edge) in the column of the list's app icons, and inside `visible`. With `listBottom` (points
    /// from the window's top edge) its top is ``listGap`` under that list, so its arrow points into
    /// it; never lower than the bottom docking, never over the toolbar. Without, it docks over the
    /// window's bottom.
    static func dockedFrame(panel size: NSSize, iconCenter: CGFloat, settings: NSRect, listBottom: CGFloat? = nil,
                            visible: NSRect?) -> NSRect {
        let bottom = settings.minY + inset
        var y = bottom
        if let listBottom {
            let under = settings.maxY - listBottom - listGap - size.height
            y = max(bottom, min(under, settings.maxY - toolbarHeight - size.height))
        }
        var frame = NSRect(x: settings.minX + listIconCenter - iconCenter, y: y, width: size.width, height: size.height)
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

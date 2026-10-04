public import AppKit
import os

/// The child windows a main window may have: its overlay host panel and the
/// Chromium page windows. Every app overlay draws on the host
/// (`WindowOverlayHost`), so nothing of the app can fall below a page that
/// the CEF fork re-adds above every child.
///
/// Presenters that still add a panel of their own are listed in
/// `legacyPanels` until they move onto the host; each move removes its entry.
/// The main window's `addChildWindow` override calls `check(_:parent:)`.
/// DEBUG and test builds record every violation (`violations`) and, when
/// `isStrict` (tests, `CMUX_NEXT_STRICT_CHILD_WINDOWS=1`), stop at it.
@MainActor
public enum ChildWindowPolicy {
    /// Panel classes allowed until their presenter moves onto the host (by class name).
    /// `NSPanel`: the restart notice uses a plain panel; `_NSPopoverWindow`: AppKit popovers.
    public static var legacyPanels: Set<String> = [
        "DividerMousePanel", "PalettePanel", "SuggestionWindow", "PageInfoPanel",
        "TabGroupEditorPanel", "HoverCardPanel", "AppearanceStudioPanel", "NSPanel", "FeedPanel",
        "BrowserPopupPanel", "NotificationsPanel", "_NSPopoverWindow",
    ]

    public private(set) static var violations: [String] = []
    public static var isStrict = ProcessInfo.processInfo.environment["CMUX_NEXT_STRICT_CHILD_WINDOWS"] == "1"
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "overlay")

    /// Whether `child` may be a child window of a main window `parent`.
    public static func allows(_ child: NSWindow, parent: NSWindow) -> Bool {
        if WindowOverlayHost.isPageWindow(child) { return true }
        if let host = WindowOverlayHost.existingHost(for: parent), child === host.panel { return true }
        if child is OverlayHostPanel { return true }
        return legacyPanels.contains(String(describing: type(of: child)))
    }

    /// Records (and in strict mode stops at) a child that is neither the host
    /// panel, a page window nor a listed legacy panel. Returns whether it is allowed.
    @discardableResult
    public static func check(_ child: NSWindow, parent: NSWindow) -> Bool {
        guard !allows(child, parent: parent) else { return true }
        let name = String(describing: type(of: child))
        #if DEBUG
        violations.append(name)
        logger.fault("child window \(name, privacy: .public) is not on the overlay host; it can fall below a Chromium page")
        if isStrict { assertionFailure("child window \(name) is not on the overlay host") }
        #endif
        return false
    }

    /// Forgets recorded violations (tests).
    public static func resetViolations() { violations.removeAll() }
}

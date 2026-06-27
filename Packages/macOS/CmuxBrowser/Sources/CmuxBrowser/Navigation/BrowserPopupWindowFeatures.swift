public import Foundation
public import WebKit

/// The popup window-feature primitives WebKit surfaces for a scripted
/// `window.open`, used to decide whether the script requested explicit popup
/// chrome or geometry (and therefore a real popup window) versus a bare
/// `_blank`-style new tab.
///
/// The classification is a stateless read of the optional geometry and chrome
/// values; ``wereSpecified`` is true when the script requested any of them.
public struct BrowserPopupWindowFeatures {
    /// The requested window x-origin, if any.
    public let x: NSNumber?
    /// The requested window y-origin, if any.
    public let y: NSNumber?
    /// The requested window width, if any.
    public let width: NSNumber?
    /// The requested window height, if any.
    public let height: NSNumber?
    /// The requested menu-bar visibility, if any.
    public let menuBarVisibility: NSNumber?
    /// The requested status-bar visibility, if any.
    public let statusBarVisibility: NSNumber?
    /// The requested toolbars visibility, if any.
    public let toolbarsVisibility: NSNumber?
    /// The requested resizing allowance, if any.
    public let allowsResizing: NSNumber?

    /// Captures the raw popup feature values.
    public init(
        x: NSNumber?,
        y: NSNumber?,
        width: NSNumber?,
        height: NSNumber?,
        menuBarVisibility: NSNumber?,
        statusBarVisibility: NSNumber?,
        toolbarsVisibility: NSNumber?,
        allowsResizing: NSNumber?
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.menuBarVisibility = menuBarVisibility
        self.statusBarVisibility = statusBarVisibility
        self.toolbarsVisibility = toolbarsVisibility
        self.allowsResizing = allowsResizing
    }

    /// Captures the popup feature values surfaced by WebKit.
    public init(windowFeatures: WKWindowFeatures) {
        self.init(
            x: windowFeatures.x,
            y: windowFeatures.y,
            width: windowFeatures.width,
            height: windowFeatures.height,
            menuBarVisibility: windowFeatures.menuBarVisibility,
            statusBarVisibility: windowFeatures.statusBarVisibility,
            toolbarsVisibility: windowFeatures.toolbarsVisibility,
            allowsResizing: windowFeatures.allowsResizing
        )
    }

    /// Whether the script specified any popup geometry or chrome visibility.
    public var wereSpecified: Bool {
        x != nil ||
            y != nil ||
            width != nil ||
            height != nil ||
            menuBarVisibility != nil ||
            statusBarVisibility != nil ||
            toolbarsVisibility != nil ||
            allowsResizing != nil
    }
}

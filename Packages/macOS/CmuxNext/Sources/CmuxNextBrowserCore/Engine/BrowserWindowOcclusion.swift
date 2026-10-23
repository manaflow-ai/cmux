public import AppKit
public import Foundation

/// Implemented by a window that has its own native overlays taking the
/// mouse over its content (split dividers, the screen switcher). Pages that
/// are child windows (`.childWindow`) leave those rects uncovered: they are
/// masked there and the mouse goes to the window.
@MainActor
public protocol BrowserWindowOcclusionProviding: AnyObject {
    /// Rects in window coordinates.
    var browserOcclusionRectsInWindow: [CGRect] { get }
    /// Rects in window coordinates that take the mouse but draw nothing over
    /// the content (divider hit areas). A page that draws in its own window
    /// keeps drawing there (the window covers them some other way); a page whose
    /// pixels are in this window's layer tree (layer hosting, fork API 26) draws
    /// nothing in its window, so it leaves them uncovered too and the mouse
    /// goes to the window.
    var browserMouseOnlyRectsInWindow: [CGRect] { get }
    /// A page over `host` (a view in this window) started or stopped drawing in
    /// this window's layer tree instead of its own window.
    func browserPageHostingDidChange(_ host: NSView, hosted: Bool)
}

public extension BrowserWindowOcclusionProviding {
    var browserMouseOnlyRectsInWindow: [CGRect] { [] }
    func browserPageHostingDidChange(_ host: NSView, hosted: Bool) {}
}

extension Notification.Name {
    /// Post (object: the `NSWindow`) to make every child-window page of that
    /// window re-apply its geometry, clip and occlusion: when
    /// ``BrowserWindowOcclusionProviding/browserOcclusionRectsInWindow``
    /// changes, and after the window moved or resized by any means (drag,
    /// Accessibility clients such as Rectangle, display or Space changes,
    /// fullscreen, deminiaturize).
    /// A page only re-applies when something it reads changed since the fork last read it, unless
    /// the post's `userInfo` has ``browserPagesForceUpdateKey`` true.
    public static let browserChildWindowPagesNeedUpdate = Notification.Name("CmuxBrowserChildWindowPagesNeedUpdate")
}

/// `userInfo` key of ``Foundation/Notification/Name/browserChildWindowPagesNeedUpdate``: true makes every
/// page re-apply even where nothing it reads changed (a page window that something other than the fork
/// moved, such as an Accessibility client, goes back over its host).
public let browserPagesForceUpdateKey = "force"

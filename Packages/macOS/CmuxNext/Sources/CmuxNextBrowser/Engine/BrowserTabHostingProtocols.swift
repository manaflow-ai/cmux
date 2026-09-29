public import AppKit
public import Foundation

/// Tabs whose page is drawn above the host window (`.childWindow`
/// presentation) and therefore need to be told where native UI covers them.
public protocol BrowserOcclusionHosting: AnyObject {
    /// Rects in `contentView` coordinates where native UI (glass overlays,
    /// find bar, prompt bar) must show above the page. The page is masked
    /// there and mouse events go to the host window.
    var occlusionRects: [CGRect] { get set }
}

/// Tabs that expose Chrome extension toolbar actions. `BrowserChromeView`
/// fills its `extensionSlot` from this automatically.
public protocol BrowserExtensionActionHosting: AnyObject, Observable {
    /// Current actions, observable.
    var extensionActions: [CEFExtensionAction] { get }
    /// Performs the action (popup, `onClicked`). `anchor` is the button's
    /// rect in `contentView` coordinates; the popup opens below its top edge.
    func runExtensionAction(_ id: String, anchor: CGRect)
    /// Shows Chromium's action menu (pin, options, remove, site access) at
    /// a point in screen coordinates.
    func showExtensionActionMenu(_ id: String, atScreenPoint point: CGPoint)
}

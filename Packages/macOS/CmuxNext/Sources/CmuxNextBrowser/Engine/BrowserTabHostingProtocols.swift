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
    /// The extension whose action popup is open, observable (nil when none).
    var openExtensionPopup: String? { get }
    /// False hides the Extensions button (a mock page without extensions).
    var showsExtensionToolbar: Bool { get }
    /// Where the chrome shows `id`'s action: its toolbar button, or the
    /// Extensions button when the action is not visible, in `contentView`
    /// coordinates. Set by the chrome that binds the tab.
    var extensionActionAnchor: ((String) -> CGRect?)? { get set }
    /// Performs the action (popup, `onClicked`). `anchor` is the button's
    /// rect in `contentView` coordinates; the popup opens below its top edge.
    func runExtensionAction(_ id: String, anchor: CGRect)
    /// Closes any open action popup of this tab's window.
    func hideExtensionPopups()
    /// Shows Chromium's action menu (pin, options, remove, site access) at
    /// a point in screen coordinates.
    func showExtensionActionMenu(_ id: String, atScreenPoint point: CGPoint)
    /// The installed extensions of the tab's profile, with management calls.
    var extensionStore: BrowserExtensionStore { get }
}

extension BrowserExtensionActionHosting {
    public var showsExtensionToolbar: Bool { true }

    /// Runs `id`'s action anchored where the chrome shows it (a shortcut,
    /// the palette, the CLI or the Extensions menu).
    public func requestExtensionAction(_ id: String) {
        runExtensionAction(id, anchor: extensionActionAnchor?(id) ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}


/// Tabs whose engine reports a hung page and lets the user choose (Chrome's
/// "Page unresponsive": Wait or Exit page).
public protocol BrowserHangAnswering: AnyObject {
    /// `terminate` false waits (the engine restarts its hang timer); true
    /// ends the page's process, which shows the sad tab.
    func answerUnresponsivePage(terminate: Bool)
}

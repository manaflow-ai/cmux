public import AppKit

/// A browser page that hosts Chromium extensions.
///
/// The Chromium engine's page conforms; the WebKit page does not, so callers
/// test `page as? any BrowserExtensionHosting` and report that extensions
/// need the Chromium engine otherwise. Conformers are `@Observable`, so a
/// view reading ``extensionActions`` or ``openExtensionPopup`` updates.
@MainActor
public protocol BrowserExtensionHosting: AnyObject {
    /// The page's profile extension store (shared by every page of the profile).
    var extensionStore: BrowserExtensionStore { get }
    /// The page as a target for tab-scoped extension calls.
    var extensionTab: any BrowserExtensionTab { get }
    /// The toolbar actions for this page, in Chromium's toolbar order.
    var extensionActions: [BrowserExtensionAction] { get }
    /// The view Chromium draws the page in (popups anchor to its top edge),
    /// which is inside the page's content view when DevTools is docked.
    var extensionPageView: NSView? { get }
    /// The extension whose action popup is open, if any.
    var openExtensionPopup: String? { get }
    /// Runs an extension's toolbar action; its popup hangs below `anchor`
    /// (the button's frame, in the page view's coordinates, top-left origin).
    @discardableResult
    func runExtensionAction(_ id: String, anchor: CGRect) -> Bool
    /// Closes the open action popup.
    func hideExtensionPopup()
    /// Re-reads the page's toolbar actions.
    func refreshExtensionActions()
    /// Runs an action requested by a shortcut or automation, anchored by the
    /// toolbar (set by the toolbar while it is shown; nil anchors at the page's leading edge).
    var extensionActionRequestHandler: (@MainActor (String) -> Void)? { get set }
    /// Shows Chromium's own menu for an extension (site access and more) at
    /// a point in AppKit screen coordinates.
    func showExtensionActionMenu(_ id: String, atScreenPoint point: CGPoint)
}

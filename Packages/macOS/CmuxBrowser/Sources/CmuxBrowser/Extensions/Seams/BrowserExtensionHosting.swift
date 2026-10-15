/// A browser page that hosts Chromium extensions.
///
/// The Chromium engine's page conforms; the WebKit page does not, so callers
/// test `panel.page as? any BrowserExtensionHosting` and report that
/// extensions need the Chromium engine otherwise. Pages advertising
/// ``BrowserEngineCapabilities/extensions`` conform.
@MainActor
public protocol BrowserExtensionHosting: AnyObject {
    /// The page's profile extension store (shared by every page of the profile).
    var extensionStore: BrowserExtensionStore { get }
    /// The page as a target for tab-scoped extension calls.
    var extensionTab: any BrowserExtensionTab { get }
    /// The toolbar actions for this page, in Chromium's toolbar order.
    var extensionActions: [BrowserExtensionAction] { get }
}

public import CmuxBrowserStream
public import CmuxMobileHost
public import CoreGraphics
public import Foundation

/// The app's browser tabs as the phone link reaches them (c2-browser-stream.md
/// 9). The app implements it over its tab model and engines; this module
/// never imports the browser.
@MainActor
public protocol MobileBrowserTabs: AnyObject, Sendable {
    /// A browser tab (`tab_…`) of this Mac's workspaces; nil for any other id
    /// (incognito tabs are not offered).
    func tab(_ id: String) -> (any MobileBrowserTab)?
}

/// One live page as the phone stream needs it.
@MainActor
public protocol MobileBrowserTab: AnyObject, Sendable {
    /// Where the page is on screen now; nil while no window shows it.
    var placement: MobileBrowserPlacement? { get }
    var geometry: BrowserPageGeometry { get }
    var page: RbPage { get }
    /// Yields on every page, geometry or placement change; finishes when the tab closes.
    func changes() -> AsyncStream<Void>
    /// One DevTools command on the page (trusted input). Throws when the
    /// engine has no DevTools channel (WebKit pages).
    func devTools(method: String, params: [String: any Sendable]) async throws
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}

/// The window that shows a page and the page's rect in it (window points,
/// top-left origin), what ScreenCaptureKit captures.
public struct MobileBrowserPlacement: Hashable, Sendable {
    public var windowID: CGWindowID
    public var rect: CGRect

    public init(windowID: CGWindowID, rect: CGRect) {
        self.windowID = windowID
        self.rect = rect
    }
}

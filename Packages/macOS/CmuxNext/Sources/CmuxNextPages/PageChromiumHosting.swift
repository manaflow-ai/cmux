public import AppKit
public import CmuxNextSettings
public import Foundation

/// Makes Chromium pages for the page host (``PageWebView``). The app implements it with its CEF
/// engine and hands it to the page host once at startup (``PageWebView/chromiumHosting``); this
/// module does not depend on the browser module, so tests pass a fake.
@MainActor
public protocol PageChromiumHosting: AnyObject {
    /// The person's `browser.defaultEngine`, read for every new page.
    var preference: BrowserDefaultEngine { get }
    /// Whether Chromium can host a page now: false when the build has no Chromium or it failed to
    /// start.
    var isAvailable: Bool { get }
    /// Whether Chromium's `cmux-page://` scheme serves `page` (its bundled folder is registered).
    ///
    /// - Parameter page: The page to show.
    /// - Returns: True when a Chromium page can load it.
    func serves(_ page: PageDescriptor) -> Bool
    /// Makes an empty Chromium page for `page` and returns once its browser exists, before any
    /// document loads, so the host can set the page up
    /// (``ChromiumPageHostBridge/setupCalls(handlers:documentScripts:)``) and then call
    /// ``PageChromiumPage/load(_:)``. Async because Chromium starts on its first page.
    ///
    /// - Parameter page: The page's descriptor (its origin and policy).
    /// - Returns: The live page.
    /// - Throws: When Chromium cannot start or the browser is not created.
    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage
    /// `page`'s Chromium page attached after the page showed (a cold New Tab page at the first Cmd-N
    /// of a launch), so the view that takes its keyboard (``PageWebView/focusView``) changed under it.
    /// The app applies the focus model of the pane whose own page `page` is again, which hands the
    /// keys to the Chromium page in one key change.
    ///
    /// - Parameter page: The page whose keyboard view changed.
    /// - Returns: Whether a focus model owns `page`'s keys; if not, the page takes the keyboard itself
    ///   when its WebKit view had it.
    func focusViewChanged(_ page: PageWebView) -> Bool
}

extension PageChromiumHosting {
    /// No focus model: the page keeps its keyboard itself.
    public func focusViewChanged(_ page: PageWebView) -> Bool { false }
}

/// One Chromium page the page host shows. The page host drives it only through this protocol
/// and the DevTools protocol (``devTools(_:params:)``), so a CEF tab or a fake in tests both fit.
@MainActor
public protocol PageChromiumPage: AnyObject {
    /// The view to place where the page shows (Chromium's view tracks it).
    var contentView: NSView { get }
    /// Receives the page's raw DevTools protocol events and its load and crash events. Set it
    /// before the first ``devTools(_:params:)`` call.
    var onEvent: ((PageChromiumEvent) -> Void)? { get set }
    /// Answers the page's requests for its dynamic paths (``PageDescriptor/dynamicPrefixes``):
    /// Chromium asks it for every request under one, and a nil answerer is a 404. The host sets it
    /// before the first ``load(_:)``.
    var resources: (@MainActor (URL) async -> PageChromiumResponse)? { get set }
    /// Rects in ``contentView``'s coordinates where native UI of the host window shows over the
    /// page. A Chromium page is a child window above the whole host window, so the page window
    /// leaves these rects uncovered: the native view under them shows there and takes the mouse
    /// (a chat's pane tabs while the chat shares the tab row, ``PageWebView/nativeRects``).
    var occlusionRects: [CGRect] { get set }
    /// Runs a DevTools protocol method and returns its JSON result.
    ///
    /// - Parameters:
    ///   - method: The method (`Runtime.evaluate`).
    ///   - params: Its params.
    /// - Returns: The method's JSON result.
    /// - Throws: When the page is gone or the method fails.
    func devTools(_ method: String, params: [String: any Sendable]) async throws -> String
    /// Loads `url` in the page.
    func load(_ url: URL)
    /// Reloads the document.
    func reload()
    /// Sets the page zoom (1 is 100%).
    func setZoom(_ zoom: Double)
    /// Gives or takes the keyboard focus.
    func setFocused(_ focused: Bool)
    /// Shows or hides and pauses the page.
    func setVisible(_ visible: Bool)
    /// Makes the page see-through (true) or gives it its opaque page color back: where the document
    /// draws no background of its own, the view under the page shows, as under a WebKit page that
    /// draws no background.
    func setSeeThrough(_ seeThrough: Bool)
    /// Tears the page down. Idempotent.
    func close()
}

/// What a Chromium page reports to the page host.
public nonisolated enum PageChromiumEvent: Sendable, Equatable {
    /// A raw DevTools protocol message (an event of a domain the host turned on).
    case devTools(String)
    /// A new main-frame document committed at `url`.
    case committed(URL?)
    /// The document finished loading.
    case finished
    /// The page's render process ended.
    case crashed
    /// The Chromium browser itself went away (not closed by the host): the page cannot come back
    /// in Chromium.
    case ended
    /// The page asked to open `url` in a new tab or window (`window.open`, a `target=_blank` link).
    case openRequested(URL)
    /// A drag of these files from outside the app entered the page (their paths, which the page
    /// itself never learns). The page still gets the drag.
    case filesDragged([URL])
    /// A real key or mouse event reached the page (its `systemUptime`): what backs a page call as the
    /// person's gesture (``PageWebView/lastUserEventUptime``). Page script cannot make one.
    case userInput(TimeInterval)
    /// The person right-clicked in the page: the host shows its own menu (``PageChromiumContextMenu``).
    case contextMenu(PageChromiumContextMenu)
}

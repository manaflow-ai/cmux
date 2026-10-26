public import AppKit
public import CmuxNextSettings
public import CmuxNextWakeups
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
    /// The app's lanes: what a page answers that costs CPU by its size (a `Page.captureScreenshot` reply, megabytes
    /// of base64 image) is parsed and decoded on their `.cpu` lane, never on the main thread.
    var work: BackgroundWork { get }
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
}

/// One Chromium page the page host shows. The page host drives it only through this protocol
/// (scripts through ``evaluate(_:)``, the rest through the DevTools protocol,
/// ``devTools(_:params:)``), so a CEF tab or a fake in tests both fit.
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
    /// Whether `window` is the Chromium window that draws this page now: a child of
    /// ``contentView``'s window, over it. An event in that window is this page's input and no other
    /// page's, even when another page's window sits at the same frame (a hidden tab of the same pane).
    func isPageWindow(_ window: NSWindow) -> Bool
    /// Runs a DevTools protocol method and returns its JSON result.
    ///
    /// - Parameters:
    ///   - method: The method (`Page.captureScreenshot`).
    ///   - params: Its params.
    /// - Returns: The method's JSON result.
    /// - Throws: When the page is gone or the method fails.
    func devTools(_ method: String, params: [String: any Sendable]) async throws -> String
    /// Runs `script` in the page's main frame, in the page's own world, without a user gesture,
    /// and returns its value by value, a promise's once it settles. A value that is not a promise
    /// comes back as it is, so a synchronous script (the input-readiness edit) gets what a
    /// `Runtime.evaluate` without `awaitPromise` gave. Chrome's WebUI runs its scripts in its page
    /// with no DevTools agent (`WebUIImpl::ExecuteJavascript`, content/browser/webui/web_ui_impl.cc);
    /// a CEF page answers through `CEFTab.evaluate`, which is the fork's `tabEvaluate` on renderer
    /// paths (fork API 29) and a DevTools `Runtime.evaluate` on an older fork. Every conformer
    /// chooses its path; ``devToolsEvaluate(_:)`` is the DevTools one.
    ///
    /// - Parameter script: An expression, or statements whose last value is the result.
    /// - Returns: The value as `JSONSerialization` makes it (`NSNumber`, `String`, arrays,
    ///   dictionaries), `NSNull` for null, nil for undefined where the engine tells it from null
    ///   (`CEFTab.evaluate` gives null for both).
    /// - Throws: ``PageScriptError/exception(_:)`` when the script throws,
    ///   ``PageScriptError/noResult`` when the answer is not JSON, or the page's error when it is gone.
    func evaluate(_ script: String) async throws -> Any?
    /// Copies the page as it last drew, fitted inside `maxPixelSize` (never scaled up), with no DevTools
    /// agent: the fork's surface copy (`cmux_tab_copy_surface`, p13-webui-077), as Chrome copies a tab
    /// thumbnail (chrome/browser/ui/thumbnails/thumbnail_tab_helper.cc, `RenderWidgetHostView::CopyFromSurface`).
    /// Chromium encodes the picture on its thread pool. The page lifecycle takes it in the turn the page
    /// hides, before any freeze (``PageWebView/keepHideSnapshot()``). Never `Page.captureScreenshot`: one
    /// DevTools agent ends main-frame renderer reuse for the whole browser.
    ///
    /// - Parameters:
    ///   - maxPixelSize: The largest picture, in pixels.
    ///   - done: Runs once on the main actor with the picture, or nil when the page has no surface or the
    ///     fork has no surface copy.
    func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (PageEncodedSnapshot?) -> Void)
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

extension PageChromiumPage {
    /// ``evaluate(_:)`` through a DevTools `Runtime.evaluate` (`awaitPromise`, `returnByValue`), for
    /// a page with no renderer path. The reply is parsed off the main actor in one step.
    ///
    /// - Parameter script: The script.
    /// - Returns: The value; `NSNull` for null, nil for undefined.
    /// - Throws: ``PageScriptError`` for an exception or a reply that is not JSON, or the page's error.
    public func devToolsEvaluate(_ script: String) async throws -> Any? {
        let reply = try await devTools("Runtime.evaluate", params: ["expression": script, "awaitPromise": true, "returnByValue": true])
        return try await ChromiumPageHostWire.value(devToolsReply: reply)
    }
}

/// A picture of a page, encoded (PNG, alpha kept): what a page keeps of its last frame once it is
/// discarded (``PageHideState``), copied by Chromium (``PageChromiumPage/copySurface(maxPixelSize:done:)``)
/// or encoded from WebKit's frame by ``PageSnapshotEncoder``.
public nonisolated struct PageEncodedSnapshot: Sendable, Equatable {
    /// The encoded image.
    public var data: Data
    /// Its size in pixels.
    public var pixelSize: CGSize

    /// - Parameters:
    ///   - data: The encoded image.
    ///   - pixelSize: Its size in pixels.
    public init(data: Data, pixelSize: CGSize) {
        self.data = data
        self.pixelSize = pixelSize
    }
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

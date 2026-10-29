public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextSettings
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
    /// The dialog center a page's own notices show in (its "Page unresponsive" card, ``PageChromiumEvent/unresponsive``):
    /// the app's one center, or a test's headless one.
    var dialogs: CmuxDialogCenter { get }
    /// Whether Chromium's `cmux-page://` scheme serves `page` (its bundled folder is registered).
    ///
    /// - Parameter page: The page to show.
    /// - Returns: True when a Chromium page can load it.
    func serves(_ page: PageDescriptor) -> Bool
    /// The origin of a page the launch restored (``PageOpenOrigin/launchRestore``) that starts now: the engine's
    /// launch order's, ``PageChromiumOrigin/restoreVisible`` when it shows (`isShown`), else
    /// ``PageChromiumOrigin/restoreHidden``; ``PageChromiumOrigin/user`` once startup completed, or with no launch
    /// order (feature `cefLaunchOrigin` off).
    func restoredOrigin(isShown: Bool) -> PageChromiumOrigin
    /// Runs `start` for a restored page that does not show, at the first of: `node` shows, or startup completes
    /// (the launch order's afterStartup post); at once when no launch runs. `start` may run twice and must start
    /// the page once.
    func startHidden(when node: VisibilityNode, _ start: @escaping @MainActor @Sendable () -> Void)
    /// Makes an empty Chromium page for `page` and returns once its browser exists, before any
    /// document loads, so the host can set the page up
    /// (``ChromiumPageHostBridge/setUp(documentScripts:)``) and then call
    /// ``PageChromiumPage/load(_:)``. Async because Chromium starts on its first page.
    ///
    /// - Parameters:
    ///   - page: The page's descriptor (its origin and policy).
    ///   - chatOpen: The agent chat open the page shows (``PageWebView/chatOpen``): the stages of the Chromium window
    ///     the page gets (its create, created and first contentful paint) go there too; nil for any other page.
    ///   - window: The pane window the page joins (``PageChromiumWindow``); nil gives the page a window of its own.
    ///   - origin: Why the page starts now; the host passes it on as the engine's tab origin, whose launch order
    ///     is the only wait (a restored page's start waits there, never in the page).
    /// - Returns: The live page.
    /// - Throws: ``PageChromiumStartError/browserEnded`` when the browser ended with its Chromium Host
    ///   before it existed; another error when Chromium cannot start or the browser is not created.
    func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, window: PageChromiumWindow?,
                  origin: PageChromiumOrigin) async throws -> any PageChromiumPage
    /// What follows the end of a page's Chromium browser (``PageChromiumEvent/ended``): `answer` runs
    /// once Chromium runs again or its supervisor gave up (plans/cmux-next/cef-helper-app-DESIGN.md: a
    /// Chromium Host that ends again within 60 s of its start stays ended). Every page whose browser
    /// ended asks, and all of them get the one outcome of that end. A Chromium that runs in cmux's
    /// own process cannot start again: it answers ``PageChromiumSupervisorOutcome/gaveUp`` in the call.
    ///
    /// - Parameter answer: Gets whether Chromium came back, on the main actor.
    func supervisorOutcome(then answer: @escaping @MainActor @Sendable (PageChromiumSupervisorOutcome) -> Void)
}

/// The Chromium window a page tab shows in: the page tabs of one cmux pane of one main
/// window share one, as a Chrome `Browser` holds every tab of its tab strip in one window
/// (chrome/browser/ui/browser.h, `Browser::tab_strip_model`). A second page in the pane joins that
/// window instead of building one. A page with none (the update card, the icon picker panel, a
/// preload) keeps a window of its own.
public nonisolated struct PageChromiumWindow: Hashable, Sendable {
    /// The main window's id.
    public var window: String
    /// The pane's key in that window.
    public var pane: String

    /// - Parameters:
    ///   - window: The main window's id.
    ///   - pane: The pane's key.
    public init(window: String, pane: String) {
        self.window = window
        self.pane = pane
    }
}

/// One Chromium page the page host shows. The page host drives it only through this protocol
/// (scripts through ``evaluate(_:)``, pictures through ``copySurface(maxPixelSize:done:)``, clicks
/// and moves through ``sendClick(at:)`` and ``sendMouseMove(at:)``; the DevTools protocol,
/// ``devTools(_:params:)``, only where the engine has no such path), so a CEF tab or a fake in tests both
/// fit. On the fork's renderer paths (``usesRendererPaths``) the page host opens no DevTools session at all.
@MainActor
public protocol PageChromiumPage: AnyObject {
    /// The view to place where the page shows (Chromium's view tracks it).
    var contentView: NSView { get }
    /// Receives the page's events: its load and crash events, its posts to the page host on the
    /// page channel (``PageChromiumEvent/pageHostPost(_:sender:)``), and its raw DevTools protocol
    /// events (none on renderer paths). Set it before the first ``devTools(_:params:)`` call.
    var onEvent: ((PageChromiumEvent) -> Void)? { get set }
    /// The page runs on the fork's renderer paths (fork API 29, with the feature
    /// `chromiumPageRendererPaths` on when Chromium started): its renderer already has the page
    /// script and the shared document scripts in every `cmux-page:` main frame at document start,
    /// its posts come as ``PageChromiumEvent/pageHostPost(_:sender:)``, its document events come from
    /// the browser, and ``evaluate(_:)`` runs scripts. The page host then makes no
    /// ``devTools(_:params:)`` call for setup, messages or typed edits: a DevTools agent keeps
    /// Chromium from sharing the page's renderer. False otherwise.
    var usesRendererPaths: Bool { get }
    /// Answers the page's requests for its dynamic paths (``PageDescriptor/dynamicPrefixes``):
    /// Chromium asks it for every request under one, and a nil answerer is a 404. The host sets it
    /// before the first ``load(_:)``.
    var resources: (@MainActor (URL) async -> PageChromiumResponse)? { get set }
    /// The DOM event the page's main frame fires to post to the host on the engine's page channel
    /// (fork API 29); its posts then arrive as ``PageChromiumEvent/pageHostPost(_:sender:)``. Nil when the
    /// engine has no page channel: the page calls its DevTools binding, whose calls arrive in
    /// ``PageChromiumEvent/devTools(_:)`` (``ChromiumPageHostBridge``).
    var pageHostEvent: String? { get }
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
    /// - Throws: ``PageChromiumStartError/browserEnded`` when the page's browser ended with its
    ///   Chromium Host; another error when the page is gone or the method fails.
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
    /// Whether ``copySurface(maxPixelSize:done:)`` can give a picture. False on a fork without the surface
    /// copy: there a picture someone asks for (a window image, a debug snapshot, a cover) is a DevTools
    /// `Page.captureScreenshot`, and the hide picture is none.
    var copiesSurface: Bool { get }
    /// A left click at `point` (view points from the top-left of ``contentView``) as the person's own,
    /// with no DevTools agent: the fork's native click (`CefBrowserHost::SendMouseClickEvent`, fork API 29).
    ///
    /// - Parameter point: Where to click, in view points.
    /// - Returns: False when the engine has no native click or the page is gone: the caller then uses
    ///   DevTools input.
    func sendClick(at point: CGPoint) -> Bool
    /// The mouse moves to `point` (view points from the top-left of ``contentView``) with no button held, as the
    /// person's own, with no DevTools agent: the fork's native move (`CefBrowserHost::SendMouseMoveEvent`).
    ///
    /// - Parameter point: Where the pointer goes, in view points.
    /// - Returns: False when the engine has no native move or the page is gone: the caller then uses DevTools input.
    func sendMouseMove(at point: CGPoint) -> Bool
    /// Copies the page's selection to the pasteboard as the person's own Copy (a menu choice backs it):
    /// `document.execCommand('copy')` with a user gesture, through the fork's `tabEvaluate` on renderer
    /// paths (fork API 29), so it makes no DevTools call there.
    func copySelection()
    /// Whether ``push(_:)`` reaches the page: the engine has the page push channel (`cmuxPageListen`,
    /// fork API 43) and the app turned it on (feature `pagePushChannel`).
    var pushesToPage: Bool { get }
    /// Hands `text` to the receiver the page's document registered with `cmuxPageListen`, as data: no
    /// script runs for it and nothing answers, as Chrome's WebUI pages get Mojo messages instead of
    /// `WebUI::CallJavascriptFunction` scripts (content/browser/webui/web_ui_impl.cc). Pushes arrive in
    /// call order, and the engine keeps them until the document's receiver registers or a frozen page
    /// runs again. Call it only while ``pushesToPage``; otherwise it does nothing.
    ///
    /// - Parameter text: UTF-8 text, no NUL.
    func push(_ text: String)
    /// Copies the page as it last drew, fitted inside `maxPixelSize` (never scaled up), with no DevTools
    /// agent: the fork's surface copy (`cmux_browser_capture`), as Chrome copies a tab
    /// thumbnail (chrome/browser/ui/thumbnails/thumbnail_tab_helper.cc, `RenderWidgetHostView::CopyFromSurface`).
    /// Chromium encodes the picture on its thread pool. The page lifecycle takes it in the turn the page
    /// hides, before any freeze (``PageWebView/keepHideSnapshot(encoder:)``). Never `Page.captureScreenshot`: one
    /// DevTools agent ends main-frame renderer reuse for the whole browser.
    ///
    /// - Parameters:
    ///   - maxPixelSize: The largest picture, in pixels.
    ///   - done: Runs once on the main actor with the picture as the engine answers it (base64, decoded
    ///     off the main thread by its users), or nil when the page has no surface or the fork has no
    ///     surface copy.
    func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (PageSurfaceCopy?) -> Void)
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
    /// Moves the page into `window` (its tab moved to another pane), document, history and renderer
    /// kept, as Chrome moves a dragged tab between tab strips with its `WebContents`
    /// (chrome/browser/ui/tabs/tab_strip_model.cc, `DetachWebContentsAtForInsertion`, then
    /// `InsertWebContentsAt`). The window it left closes once its last page left. No effect when the
    /// page is in `window` already.
    ///
    /// - Parameter window: The pane window the page shows in now.
    func moveWindow(to window: PageChromiumWindow)
    /// Freezes the hidden page (its timers, tasks and rendering stop; memory and state stay) or thaws
    /// it, as Chrome's `WebContents::SetPageFrozen` (content/public/browser/web_contents.h), which
    /// freezes hidden pages only: hide it (``setVisible(_:)`` false) before, and thaw it before it
    /// shows again. The request leaves before this returns, so a call made after a thaw runs on a
    /// live page.
    ///
    /// - Parameter frozen: True freezes, false thaws.
    /// - Returns: False when nothing changed: the page is closed, or the engine still counts it visible.
    @discardableResult
    func setFrozen(_ frozen: Bool) -> Bool
    /// Makes the page see-through (true) or gives it its opaque page color back: where the document
    /// draws no background of its own, the view under the page shows, as under a WebKit page that
    /// draws no background.
    func setSeeThrough(_ seeThrough: Bool)
    /// Discards the hidden page in place: its renderer and document go, the page keeps its browser,
    /// window and history entry, and the engine reloads that entry when the page shows; a
    /// ``load(_:)`` of the entry's URL before then adds no navigation (Chrome's `WebContents::Discard`,
    /// content/public/browser/web_contents.h). Makes no call into the page.
    ///
    /// - Returns: False when the engine cannot (a fork before in-place discard, the Chromium Host,
    ///   whose answer is not synchronous, or a page Chromium still counts visible): the host closes
    ///   the page instead.
    func discard() -> Bool
    /// Answers the page's hang (``PageChromiumEvent/unresponsive``), as Chrome's hung renderer dialog does
    /// (chrome/browser/ui/views/hung_renderer_view.cc): wait restarts Chromium's hang timer, so the page reports
    /// again if it still hangs; terminate ends its renderer, and the page reports ``PageChromiumEvent/crashed``.
    /// Makes no call into the page and never waits. A page that is not unresponsive, or is closed, ignores it.
    ///
    /// - Parameter terminate: True ends the renderer, false waits.
    func answerUnresponsive(terminate: Bool)
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

    /// ``copySurface(maxPixelSize:done:)`` awaited: the request still leaves in the caller's turn.
    ///
    /// - Parameter maxPixelSize: The largest picture, in pixels.
    /// - Returns: The picture, still in base64; nil when there is none.
    public func copiedSurface(maxPixelSize: CGSize) async -> PageSurfaceCopy? {
        try? await withOnceContinuation { (done: OnceContinuation<PageSurfaceCopy?, OnceContinuationError>) in
            copySurface(maxPixelSize: maxPixelSize) { done.resume(returning: $0) }
        }
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

/// A page's surface copy as the engine answers it (``PageChromiumPage/copySurface(maxPixelSize:done:)``): the PNG,
/// alpha kept, still in base64 as the fork's reply carries it. A full window is megabytes of text, so the main actor
/// only passes it on; ``encoded(fileID:line:)`` decodes it on the `.cpu` lane (the hide picture through
/// ``PageSnapshotEncoder``, the other pictures in ``PageWebView/chromiumPictureData(of:devToolsParams:)``).
public nonisolated struct PageSurfaceCopy: Sendable, Equatable {
    /// The encoded image in base64.
    public var base64: String
    /// Its size in pixels.
    public var pixelSize: CGSize

    /// - Parameters:
    ///   - base64: The encoded image in base64.
    ///   - pixelSize: Its size in pixels.
    public init(base64: String, pixelSize: CGSize) {
        self.base64 = base64
        self.pixelSize = pixelSize
    }

    /// The picture's PNG bytes, decoded from base64 as a checked CPU call: on the main thread, more than
    /// ``BlockingKind/cpuIntensiveJSONBytes`` of text is a cpu-intensive site. Run it on the `.cpu` lane.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The encoded picture; nil when the text holds no bytes.
    public func encoded(fileID: StaticString = #fileID, line: UInt = #line) -> PageEncodedSnapshot? {
        let data = cpuIntensiveCall(size: base64.utf8.count, limit: BlockingKind.cpuIntensiveJSONBytes,
                                    fileID: fileID, line: line) { Data(base64Encoded: base64) }
        guard let data, !data.isEmpty else { return nil }
        return PageEncodedSnapshot(data: data, pixelSize: pixelSize)
    }
}

/// Why a Chromium page did not get ready (``PageChromiumHosting/makePage(_:chatOpen:window:origin:)``,
/// ``PageChromiumPage/devTools(_:params:)``) when the page host must not reopen it in WebKit at once.
public nonisolated enum PageChromiumStartError: Error, Sendable, Equatable {
    /// The page's browser ended with its Chromium Host while it was made or set up: the page waits
    /// for the supervisor (``PageChromiumHosting/supervisorOutcome(then:)``) like a page whose shown
    /// browser ended (``PageChromiumEvent/ended``).
    case browserEnded
}

/// What a Chromium page reports to the page host.
public nonisolated enum PageChromiumEvent: Sendable, Equatable {
    /// A raw DevTools protocol message (an event of a domain the host turned on).
    case devTools(String)
    /// The page's main frame posted to the host on the page channel (``PageChromiumPage/pageHostEvent``):
    /// the text the page script sent, untrusted, and the URL of the document that sent it, which
    /// the engine's relay read where the page cannot change it.
    case pageHostPost(String, sender: URL)
    /// A new main-frame document committed at `url`.
    case committed(URL?)
    /// The document finished loading.
    case finished
    /// The page's render process ended.
    case crashed
    /// The page's renderer stopped handling input for Chromium's hang delay
    /// (`WebContentsDelegate::RendererUnresponsive`): Chromium waits for ``PageChromiumPage/answerUnresponsive(terminate:)``.
    case unresponsive
    /// The renderer handles input again, or the hang was answered (`WebContentsDelegate::RendererResponsive`).
    case responsive
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

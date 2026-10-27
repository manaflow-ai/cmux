import AppKit
import CmuxNextDesign
import WebKit

/// What a page view needs to build its WebKit engine when it first needs one: the configuration its
/// scripts and handlers were installed in, the process group a shared WebKit page joins, and the
/// host's open panel.
struct PageWebKitRecipe {
    let configuration: WKWebViewConfiguration
    let processGroups: WebProcessGroups?
    let openPanel: MadeAheadOpenPanel?
}

/// The WebKit side of one ``PageWebView``: its WKWebView, the bridge into it and its UI delegate.
///
/// A WebKit page builds it with the view. A page shown in Chromium builds it only when it falls back
/// (``PageWebView/fallBackToWebKit(_:detail:)``), so it holds no WKWebView and starts no WebKit
/// process. Chrome makes a renderer's view only for a frame whose renderer it creates
/// (`WebContentsImpl::CreateRenderWidgetHostViewForRenderManager`,
/// content/browser/web_contents/web_contents_impl.cc), never a spare one per engine.
@MainActor
final class PageWebKitEngine {
    /// The page's WebKit view.
    let view: PageWKWebView
    /// Page messages and the script FIFO's scripts in WebKit.
    let bridge: WebKitPageHostBridge
    /// The file chooser and Web Inspector's open and close (the view holds its UI delegate weakly).
    let ui: PageUIDelegate
    /// The view's sound as the page's `audible` keep reason, from ``attach(to:shown:)`` on.
    private(set) var media: PageWebKitMediaWatch?

    init(recipe: PageWebKitRecipe) {
        ui = PageUIDelegate(fileInputs: recipe.openPanel.map { PageOpenPanel(openPanel: $0) })
        // webview-allow: the page host's WebKit engine; PageEnginePolicy picks it
        let make: (WKWebViewConfiguration) -> PageWKWebView = { PageWKWebView(frame: .zero, configuration: $0) }
        // A page that shares a process joins its group (WebProcessGroups); configuration has the group's store.
        view = recipe.processGroups.map { $0.webView(for: recipe.configuration, make: make) } ?? make(recipe.configuration)
        bridge = WebKitPageHostBridge(webView: view)
        view.autoresizingMask = [.width, .height]
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        // The page is transparent; WebKit's opaque backing would hide the window's backdrop.
        // macOS has no public switch, so this uses `_setDrawsBackground:` through KVC, checked first.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }
        // Web Inspector in every build (Inspect Element, Cmd-Opt-I).
        view.isInspectable = true
        view.uiDelegate = ui
    }

    /// Wires the view to `page`: its delegate, keyboard and input hooks, keep reasons (its sound too,
    /// ``PageWebKitMediaWatch``), Web Inspector hold, the host's hooks and the page bridge.
    /// Shown when WebKit shows the page and its host shows (``PageWebView/revealWebKitView(_:)``), else
    /// hidden behind the Chromium page that does.
    func attach(to page: PageWebView, shown: Bool) {
        if shown { page.revealWebKitView(view) } else { view.isHidden = true }
        view.frame = page.bounds
        view.pageZoom = page.pageZoom
        view.navigationDelegate = page
        view.keepReasons = page.keepReasons
        media = PageWebKitMediaWatch(view: view, keepReasons: page.keepReasons)
        // The web view got the keyboard: WebKit focuses no element by itself, so the page focuses its
        // primary input (Monaco) when nothing has focus (pane-focus-DESIGN.md P1).
        view.onBecameFirstResponder = { [weak page] in page?.send(command: PageNativeOp.focusContent) }
        view.onUserEvent = { [weak page] in page?.noteTouch() }
        view.pageAcceptsFirstMouse = { [weak page] in
            guard let page else { return false }
            return page.descriptor.acceptsFirstMouse || page.engineOptions.acceptsFirstMouse
        }
        // Web Inspector stays open across reloads, as its hold does (it is the host's, not the document's).
        ui.onInspector = { [weak page] open in
            guard let keep = page?.keepReasons else { return }
            if open { keep.begin(.inspector) } else { keep.end(.inspector) }
        }
        page.webKitHooks.attach(view)
        page.inputReadiness.attach(view)
        bridge.install { [weak page] message in await page?.receive(message) }
        #if DEBUG || CMUX_BENCH_HOOKS
        // Automation launches (no activation, a GUI host whose windows macOS reports occluded):
        // WebKit stops drawing an occluded window, so captures saw an empty page. DEBUG only;
        // users keep WebKit's occlusion throttling.
        if PageWebView.rendersWhenCovered(ProcessInfo.processInfo.environment) { PageWebView.keepRenderingWhenCovered(view) }
        #endif
        // Under a Chromium page's view, as when the WebKit view was the first subview.
        page.addSubview(view, positioned: .below, relativeTo: nil)
    }
}

/// What a host sets on a page for its WebKit view (``PageWebView/fileDrop``, ``PageWebView/onFilesDropped``,
/// ``PageWebView/onPaste``, ``PageWebView/contextMenuEditor``, ``PageWebView/underPageColor``): kept
/// here, so a page with no WebKit engine keeps them (a Chromium page reads ``fileDrop`` and
/// ``contextMenuEditor`` itself), and handed to the view when the engine is built.
@MainActor
final class PageWebKitHooks {
    private weak var view: PageWKWebView?
    var fileDrop: PageFileDrop? { didSet { view?.fileDrop = fileDrop } }
    var onFilesDropped: (@MainActor ([URL]) -> Void)? { didSet { view?.onFilesDropped = onFilesDropped } }
    var onPaste: (@MainActor () -> Void)? { didSet { view?.onPaste = onPaste } }
    var contextMenuEditor: (@MainActor (NSMenu) -> Void)? { didSet { view?.contextMenuEditor = contextMenuEditor } }
    /// WebKit's under-page color; clear, so the transparent page shows the window's backdrop.
    var underPageColor: NSColor = .clear {
        // glass-opaque-allow: WKWebView's under-page color property, not the NSColor system fill; it holds the caller's theme color, clear by default
        didSet { view?.underPageBackgroundColor = underPageColor }
    }

    /// Hands every hook to `view` and keeps it current from now on.
    func attach(_ view: PageWKWebView) {
        self.view = view
        view.fileDrop = fileDrop
        view.onFilesDropped = onFilesDropped
        view.onPaste = onPaste
        view.contextMenuEditor = contextMenuEditor
        // glass-opaque-allow: WKWebView's under-page color property, not the NSColor system fill; it holds the caller's theme color, clear by default
        view.underPageBackgroundColor = underPageColor
    }
}

extension PageWebView {
    /// The WebKit engine, built now when the page has none: only WebKit's own paths read it (a WebKit
    /// page's init and ``fallBackToWebKit(_:detail:)``). A call any engine may take reads
    /// ``webKitPieces`` and does nothing in WebKit without one; a host reads ``webKitEngine``.
    var webKit: PageWebKitEngine {
        if let webKitPieces { return webKitPieces }
        let engine = PageWebKitEngine(recipe: webKitRecipe)
        webKitPieces = engine
        // Built behind a Chromium page that still shows (a WebKit-only path ran): hidden until a fallback.
        let shown = engineDecision.engine != .cef
        if shown { scriptTarget.bridge = engine.bridge }
        engine.attach(to: self, shown: shown)
        return engine
    }

    /// The WebKit view; builds the engine (``webKit``).
    var webView: PageWKWebView { webKit.view }

    /// The page's document-start scripts and handlers, also what a Chromium page installs (``PageChromiumDocumentScripts``).
    var userContent: WKUserContentController { webKitRecipe.configuration.userContentController }
}

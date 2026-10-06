import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

/// A scripted `data:` download (a page's `<a download>`) that goes to a
/// REPL session's download delegate carries WebKit's record of the frame
/// that asked for it, so the session judges the document that wrote the
/// bytes, not only the `data:` URL.
@MainActor
@Suite("Browser REPL scripted download initiator", .serialized)
struct BrowserReplScriptedDownloadInitiatorTests {
    @Test func aScriptedDataDownloadNamesTheDocumentThatAskedForIt() async throws {
        let host = BrowserReplStubWebViewHost()
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration(), host: host)
        let delegate = BrowserReplScriptedDownloadTestDelegate()
        let loads = BrowserReplScriptedDownloadTestLoads()
        delegate.loads = loads
        webView.navigationDelegate = loads
        webView.cmuxDownloadDelegate = delegate
        webView.loadHTMLString(#"<a id=a download="note.txt" href="data:text/plain,hello">x</a>"#, baseURL: URL(string: "https://writer.test/page"))
        await loads.wait { loads.finished }
        // The call gives the page a user gesture, as a person's click does.
        _ = try await webView.callAsyncJavaScript("document.getElementById('a').click()", contentWorld: .page)
        let outcome = await browserReplWithDeadline(seconds: 20) { @MainActor in
            await loads.wait { loads.started != nil }
            return loads.started
        }
        let started = try #require(outcome ?? nil, "the scripted download never reached the delegate with its initiator")
        #expect(started.url.scheme == "data")
        #expect(started.initiator.origin == "https://writer.test" && started.initiator.place == "https://writer.test")
    }
}

/// Waits for the test page's load and for the scripted download.
@MainActor
final class BrowserReplScriptedDownloadTestLoads: NSObject, WKNavigationDelegate {
    var finished = false
    var started: BrowserReplScriptedDownloadStart?
    private var waiters: [(ready: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        wake()
    }

    func wait(until ready: @escaping () -> Bool) async {
        if ready() { return }
        await withCheckedContinuation { waiters.append((ready, $0)) }
    }

    func wake() {
        let (done, pending) = (waiters.filter { $0.ready() }, waiters.filter { !$0.ready() })
        waiters = pending
        done.forEach { $0.continuation.resume() }
    }
}

struct BrowserReplScriptedDownloadStart: Sendable {
    let url: URL
    let initiator: BrowserReplFrameDocument
}

/// A download delegate that takes scripted downloads, records the frame
/// that asked for one, and cancels it.
@MainActor
final class BrowserReplScriptedDownloadTestDelegate: NSObject, WKDownloadDelegate, BrowserScriptedDownloadRouting {
    weak var loads: BrowserReplScriptedDownloadTestLoads?
    nonisolated var routesScriptedDownloadsThroughWebKit: Bool { true }

    func scriptedDownloadStarted(_ download: WKDownload, url: URL, initiator: WKFrameInfo) {
        loads?.started = BrowserReplScriptedDownloadStart(url: url, initiator: BrowserReplFrameDocument(info: initiator))
        download.cancel(nil)
        loads?.wake()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        completionHandler(nil)
    }
}

/// A web view host with no app context.
@MainActor
final class BrowserReplStubWebViewHost: CmuxWebViewHost {
    private final class Router: CmuxWebViewNavigationKeyRouting {
        func reset() {}
        func handle(_ event: NSEvent, perform: (CmuxWebViewNavigationKeyAction) -> Void) -> Bool { false }
    }
    private final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
    }
    func makeDiffViewerNavigationKeyRouter() -> any CmuxWebViewNavigationKeyRouting { Router() }
    func diffViewerEditableFocusMessageHandler() -> CmuxWebViewScriptMessageHandlerRegistration {
        CmuxWebViewScriptMessageHandlerRegistration(handler: Handler(), name: "cmuxStubFocus", contentWorld: .page)
    }
    func handleBrowserFocusModeKeyEvent(_ event: NSEvent, webView: CmuxWebView, source: String) -> BrowserFocusModeKeyDecision? { nil }
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool? { nil }
    func handleBrowserSurfaceKeyEquivalentBeforeMainMenu(_ event: NSEvent) -> Bool? { nil }
    func browserFocusModeContextMenuState(for webView: CmuxWebView) -> (isActive: Bool, canToggle: Bool)? { nil }
    func toggleBrowserFocusModeFromContextMenu(for webView: CmuxWebView) -> Bool? { nil }
    func appendScreenshotContextMenuItems(to menu: NSMenu, for webView: CmuxWebView) {}
    func routesDocumentEditingShortcutToWebContentFirst(_ event: NSEvent, responder: NSResponder?) -> Bool { false }
    func routesFindShortcutToWebContentFirst(_ event: NSEvent, responder: NSResponder?, owningWebView: CmuxWebView?) -> Bool { false }
    func routesInlineVSCodeCommandPaletteShortcutToWebContentFirst(_ event: NSEvent, pageURL: URL?) -> Bool { false }
    func isUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool { false }
    func hasLiveTabTransfer(in pasteboard: NSPasteboard) -> Bool { false }
    func hasLiveSidebarTabDrag(in pasteboard: NSPasteboard) -> Bool { false }
    func paneFirstClickFocusEnabled() -> Bool { false }
    func replacePasteboardContents(of pasteboard: NSPasteboard, with items: [NSPasteboardItem], expectedChangeCount: Int) async -> CmuxWebViewPasteboardWriteOutcome {
        CmuxWebViewPasteboardWriteOutcome(conditionNotMet: true, didWrite: false)
    }
    func typingTimingStart() -> TimeInterval? { nil }
    func typingTimingLogDuration(path: String, startedAt: TimeInterval?, event: NSEvent?, extra: String?) {}
}

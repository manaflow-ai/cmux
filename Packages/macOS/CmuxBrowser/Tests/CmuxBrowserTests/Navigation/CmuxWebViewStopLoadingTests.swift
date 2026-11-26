import AppKit
import CmuxBrowser
import Testing
import WebKit

// A navigation delegate that decides a navigation late has to know the web
// view was stopped in the meantime: WebKit voids the navigation and reports
// nothing (#53548).
@MainActor
@Suite
struct CmuxWebViewStopLoadingTests {
    @Test func everyStopIsCounted() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(frame: .zero, configuration: configuration, host: Host())
        #expect(webView.stopLoadingCount == 0)

        webView.stopLoading()
        #expect(webView.stopLoadingCount == 1)

        // The menu action is its own entry into WebKit, not a call to the first.
        webView.stopLoading(nil)
        #expect(webView.stopLoadingCount > 1)
    }

    @Test func eitherStopCancelsTheNavigationStillAwaitingItsDecision() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = CmuxWebView(frame: .zero, configuration: configuration, host: Host())
        let gate = configuration.websiteDataStore.singleSignOnNavigationGate
        var decisions: [Bool] = []
        let decide: BrowserSingleSignOnNavigationGate.Admission = { admitted in
            decisions.append(admitted)
            return false
        }

        gate.admit(gate.begin(owner: webView), url: nil, admission: decide)

        let stopped = gate.begin(owner: webView)
        webView.stopLoading()
        gate.admit(stopped, url: nil, admission: decide)

        // The menu action is its own entry into WebKit, not a call to the first.
        let stoppedFromMenu = gate.begin(owner: webView)
        webView.stopLoading(nil)
        gate.admit(stoppedFromMenu, url: nil, admission: decide)

        #expect(decisions == [true, false, false])
    }

    private final class Host: CmuxWebViewHost {
        private final class KeyRouter: CmuxWebViewNavigationKeyRouting {
            func reset() {}
            func handle(_ event: NSEvent, perform: (CmuxWebViewNavigationKeyAction) -> Void) -> Bool { false }
        }

        private final class MessageHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
        }

        func makeDiffViewerNavigationKeyRouter() -> any CmuxWebViewNavigationKeyRouting { KeyRouter() }
        func diffViewerEditableFocusMessageHandler() -> CmuxWebViewScriptMessageHandlerRegistration {
            CmuxWebViewScriptMessageHandlerRegistration(handler: MessageHandler(), name: "stopLoadingTests", contentWorld: .page)
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
}

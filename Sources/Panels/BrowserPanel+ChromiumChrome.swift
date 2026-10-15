import AppKit
import CmuxBrowser

/// Browser chrome behavior that exists only for a Chromium panel: the
/// address bar's `chrome://` pages and the page overlays' host. A WebKit
/// panel never takes these paths (`engineKind == .webkit`).
///
/// References: design spec §1 (one omnibar for both engines), cmux Next
/// `release-notes/next/highlights/new-tab-chrome-pages.md`,
/// `CmuxNextApp/ChromiumPageRouter.swift`.
extension BrowserPanel {
    /// Whether the address bar loads Chromium internal pages
    /// (`chrome://extensions`, `about:flags`) as typed. WebKit panels keep
    /// searching such text.
    var allowsChromiumInternalPages: Bool { engineKind == .chromium }

    /// Opens cmux's own page for a typed Chromium address that cmux shows
    /// itself (`chrome://settings` opens Settings > Browser). Returns whether
    /// it did, so the caller loads nothing.
    func openCmuxPageForChromiumRoute(_ input: String) -> Bool {
        guard allowsChromiumInternalPages, ChromiumPageRoute(typed: input) == .browserSettings else { return false }
        AppDelegate.shared?.openPreferencesWindow(debugSource: "browser.chromeSettings", navigationTarget: .browser)
        return true
    }

    /// The `chrome://` pages the address bar offers for `query` in this panel.
    func chromiumInternalPageCompletions(for query: String) -> [URL] {
        ChromiumPageRoute.completions(for: query, allowsChromiumSchemes: allowsChromiumInternalPages)
    }

    /// Whether `query` must not be sent to the search engine for suggestions:
    /// a Chromium internal address typed in a Chromium panel stays on this Mac.
    func keepsOmnibarQueryLocal(_ query: String) -> Bool {
        allowsChromiumInternalPages && ChromiumPageRoute.isPrivateTypedText(query)
    }

    /// Attaches the page to the overlay host: a child-window page that can
    /// leave holes gets them; anything else renders overlays in place.
    func attachPageOverlays(contentView: NSView) {
        guard let enginePage, enginePage.presentation == .childWindow,
              let target = enginePage as? any BrowserPageOcclusionHosting else {
            pageOverlays.attach(contentView: contentView, target: nil)
            return
        }
        pageOverlays.attach(contentView: contentView, target: target)
    }

    /// Where a page a Chromium page asks to open goes (`target=_blank`,
    /// `window.open`, Cmd-click, middle-click): a Chromium tab next to this
    /// panel in its pane, like a WebKit panel's new-tab links. A background
    /// tab (Cmd-click) does not take focus.
    ///
    /// A sized popup (`window.open` with features) also opens as a tab for
    /// now: keeping `window.opener` needs the engine to hand over the popup's
    /// own page (`allowPopup`), which the Chromium adapter does not offer yet.
    ///
    /// References: design spec §2 (Classic's pane tab bar is the tab strip),
    /// cmux Next `CEF/CEFWindowPolicy.swift`, `browser-link-tabs-chrome-order.md`.
    func openChromiumPageRequest(_ request: BrowserPageOpenRequest) -> BrowserPageOpenDisposition {
        guard let url = request.url else { return .block }
        switch request.placement {
        case .foregroundTab, .popup:
            openLinkInNewTab(request: URLRequest(url: url))
        case .backgroundTab:
            openLinkInNewTab(request: URLRequest(url: url), focus: false)
        }
        return .handled
    }
}

/// Answers a non-WebKit page's requests for its panel.
///
/// Chrome UI owns new pages (`openChromiumPageRequest`); permissions and
/// downloads are data's (`BrowserPanelEnginePageDelegate+Data.swift`).
/// Until their owners wire them, the rest answer the way a page with no
/// handler would be safest for: navigations proceed (typed loads already
/// passed the panel's policy) and dialogs are declined.
@MainActor
final class BrowserPanelEnginePageDelegate: BrowserPageUIDelegate {
    weak var panel: BrowserPanel?
    /// The panel's permission prompt bar questions (data: design spec §4).
    let permissionQueue = BrowserPermissionPromptQueue()
    /// Engine downloads staged into temporary files (data: design spec §3b).
    let downloadLedger = BrowserPageDownloadLedger(temporaryDirectory: BrowserDownloadDelegate.tempDir)
    /// Engine download ids the person paused.
    var pausedDownloadIDs: Set<String> = []

    func page(_ page: any BrowserPage, decidePolicyFor action: BrowserPageNavigationAction) async -> BrowserPageNavigationDecision {
        .allow
    }

    func page(_ page: any BrowserPage, requestPermission request: BrowserPagePermissionRequest) async -> BrowserPagePermissionDecision {
        await decidePermission(request).decision
    }

    func page(_ page: any BrowserPage, runJavaScriptDialog dialog: BrowserPageJavaScriptDialog) async -> BrowserPageJavaScriptDialogResponse {
        .dismiss
    }

    func page(_ page: any BrowserPage, openNewPage request: BrowserPageOpenRequest) -> BrowserPageOpenDisposition {
        panel?.openChromiumPageRequest(request) ?? .block
    }

    func page(_ page: any BrowserPage, destinationForDownload download: BrowserPageDownload) async -> URL? {
        stageDownload(download)
    }
}

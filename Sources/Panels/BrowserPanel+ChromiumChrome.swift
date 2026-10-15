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
        // Its page window can take the keyboard from now on: shortcut routing
        // must recognize it (`NSWindow.chromiumActingWindow`).
        NSWindow.noteChromiumRuntimeLoaded()
        pageOverlays.attach(contentView: contentView, target: target)
    }

    /// A page a Chromium page asks to open (`target=_blank`, `window.open`,
    /// Cmd-click, middle-click) already exists in the opener's Chromium
    /// window, with `window.opener` and `postMessage` intact. The engine
    /// hands it over (`allowPopup`, then `didCreatePopup`) and the panel hosts
    /// it as a Chromium tab next to itself in its pane, like a WebKit panel's
    /// new-tab links (`adoptChromiumPopup`). A background tab (Cmd-click) does
    /// not take focus. A sized popup opens as a tab too: Classic's popup
    /// window hosts WebKit popups only.
    ///
    /// References: design spec §2 (Classic's pane tab bar is the tab strip),
    /// cmux Next `CEF/CEFPaneHost+Popups.swift`, `CEF/CEFWindowPolicy.swift`,
    /// `browser-link-tabs-chrome-order.md`.
    func openChromiumPageRequest(_ request: BrowserPageOpenRequest) -> BrowserPageOpenDisposition {
        .allowPopup
    }

    /// Hosts `popup` (created by the engine for `request`) in a new Chromium
    /// tab beside this panel, or closes it when no tab can open.
    func adoptChromiumPopup(_ popup: any BrowserPage, for request: BrowserPageOpenRequest) {
        let focus: Bool
        switch request.placement {
        case .foregroundTab, .popup: focus = true
        case .backgroundTab: focus = false
        }
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: id, preferredWorkspaceId: workspaceId)?.workspace,
              let paneId = workspace.paneId(forPanelId: id) else {
            popup.close()
            return
        }
        Self.pendingAdoptedEnginePage = popup
        defer {
            // Not taken: no panel was created for it.
            if let pending = Self.pendingAdoptedEnginePage, pending === popup {
                Self.pendingAdoptedEnginePage = nil
                popup.close()
            }
        }
        _ = workspace.newBrowserSurface(
            inPane: paneId,
            url: nil,
            focus: focus,
            preferredProfileID: profileID,
            engine: popup.engineKind
        )
    }

    /// The popup page waiting for the panel that `adoptChromiumPopup` is
    /// creating; taken once by `makeEnginePage` during that creation.
    static var pendingAdoptedEnginePage: (any BrowserPage)?

    static func takePendingAdoptedEnginePage(engine: BrowserEngineKind) -> (any BrowserPage)? {
        guard let page = pendingAdoptedEnginePage, page.engineKind == engine else { return nil }
        pendingAdoptedEnginePage = nil
        return page
    }
}

/// Answers a non-WebKit page's requests for its panel.
///
/// Chrome UI owns new pages (`openChromiumPageRequest`). Until their owners
/// wire them, the rest answer the way a page with no handler would be safest
/// for: navigations proceed (typed loads already passed the panel's policy),
/// permission requests and dialogs are declined, and downloads are not
/// saved. Permissions, dialogs and downloads belong to the data and safety
/// parity rows, which replace these answers.
@MainActor
final class BrowserPanelEnginePageDelegate: BrowserPageUIDelegate {
    weak var panel: BrowserPanel?

    func page(_ page: any BrowserPage, decidePolicyFor action: BrowserPageNavigationAction) async -> BrowserPageNavigationDecision {
        .allow
    }

    func page(_ page: any BrowserPage, requestPermission request: BrowserPagePermissionRequest) async -> BrowserPagePermissionDecision {
        .deny
    }

    func page(_ page: any BrowserPage, runJavaScriptDialog dialog: BrowserPageJavaScriptDialog) async -> BrowserPageJavaScriptDialogResponse {
        .dismiss
    }

    func page(_ page: any BrowserPage, openNewPage request: BrowserPageOpenRequest) -> BrowserPageOpenDisposition {
        panel?.openChromiumPageRequest(request) ?? .block
    }

    func page(_ page: any BrowserPage, didCreatePopup popup: any BrowserPage, for request: BrowserPageOpenRequest) {
        guard let panel else {
            popup.close()
            return
        }
        panel.adoptChromiumPopup(popup, for: request)
    }

    func page(_ page: any BrowserPage, destinationForDownload download: BrowserPageDownload) async -> URL? {
        nil
    }
}

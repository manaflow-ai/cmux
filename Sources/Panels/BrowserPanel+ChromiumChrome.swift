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
        guard opensCmuxPage(forTyped: input) else { return false }
        AppDelegate.shared?.openPreferencesWindow(debugSource: "browser.chromeSettings", navigationTarget: .browser)
        return true
    }

    /// Whether typed text opens one of cmux's own pages instead of loading
    /// (`chrome://settings` in a Chromium panel). The address bar then shows
    /// the page's URL again, since the panel did not navigate.
    func opensCmuxPage(forTyped input: String) -> Bool {
        allowsChromiumInternalPages && ChromiumPageRoute(typed: input) == .browserSettings
    }

    /// `entries` without the Chromium-only pages (`chrome://`,
    /// `chrome-extension://`) unless the panel can show them: history is
    /// shared by both engines, and a WebKit panel's address bar must not
    /// offer a page it would search instead of opening.
    static func omnibarHistoryEntries(
        _ entries: [BrowserHistoryStore.Entry],
        allowsChromiumPages: Bool
    ) -> [BrowserHistoryStore.Entry] {
        guard !allowsChromiumPages else { return entries }
        return entries.filter { entry in
            guard let url = URL(string: entry.url) else { return true }
            return !ChromiumInternalURL.needsChromium(url)
        }
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
    /// not take focus. A sized popup (`window.open` with features) opens in
    /// Classic's popup window, as on WebKit (`ChromiumPopupWindowController`).
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
        let foreground: Bool
        switch request.placement {
        case .popup(let width, let height):
            // Sized popups (sign-in, payment) open in the same popup window
            // WebKit panels use (design review #21050, spec §0.1).
            ChromiumPopupWindowController.present(popup, width: width, height: height,
                                                  opener: enginePage?.contentView.window)
            return
        case .foregroundTab: foreground = true
        case .backgroundTab: foreground = false
        }
        // A tab nobody clicked for (an extension's `chrome.tabs.create`, a
        // script's `window.open`) is selected but never pulls the keyboard
        // out of another pane (spec §0.6).
        let focus: Bool?
        switch ChromiumUnownedTabPlacement.newTabFocus(foreground: foreground, userGesture: request.isUserGesture) {
        case .focus: focus = true
        case .selectFocusingOnlyAFocusedPane: focus = nil
        case .background: focus = false
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
            selectWhenNotFocused: foreground,
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
    /// Decides the panel's permission requests; one per panel, so a system
    /// notice shows once per page load (spec §4 v1.4).
    lazy var permissionCoordinator = BrowserPagePermissionCoordinator(
        queue: permissionQueue,
        store: { profileID in
            BrowserChromiumProfileEngineStore.current?.sitePermissions.store(forProfileID: profileID)
                ?? BrowserSitePermissionStore(fileURL: nil)
        },
        mediaAuthorization: BrowserAVMediaAuthorization.shared,
        openSystemSettings: { NSWorkspace.shared.open($0) }
    )
    /// Engine downloads staged into temporary files (data: design spec §3b).
    /// Lazy: a WebKit panel never stages one (and never creates the directory here).
    lazy var downloadLedger = BrowserPageDownloadLedger(temporaryDirectory: BrowserDownloadDelegate.tempDir)
    /// Engine download ids the person paused.
    var pausedDownloadIDs: Set<String> = []

    func page(_ page: any BrowserPage, decidePolicyFor action: BrowserPageNavigationAction) async -> BrowserPageNavigationDecision {
        .allow
    }

    func page(_ page: any BrowserPage, requestPermission request: BrowserPagePermissionRequest) async -> BrowserPagePermissionDecision {
        await decidePermission(request).decision
    }

    func page(_ page: any BrowserPage, runJavaScriptDialog dialog: BrowserPageJavaScriptDialog) async -> BrowserPageJavaScriptDialogResponse {
        await panel?.runEngineJavaScriptDialog(dialog) ?? .dismiss
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
        stageDownload(download)
    }
}

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
}

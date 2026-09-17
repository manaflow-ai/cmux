import CmuxBrowser
import Foundation

/// Browser creation options shared by main-workspace and Dock split hosts.
struct BrowserSplitRequest: Sendable {
    let url: URL?
    let focus: Bool
    let preferredProfileID: UUID?
    let chromeVisibility: BrowserChromeVisibility
    let transparentBackground: Bool
    let bypassRemoteProxy: Bool?
    let preloadInitialNavigationInBackground: Bool
    let selectWhenNotFocused: Bool
    let allowsExternalBrowserFallback: Bool

    init(
        url: URL?,
        focus: Bool,
        preferredProfileID: UUID? = nil,
        chromeVisibility: BrowserChromeVisibility = .visible,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool? = nil,
        preloadInitialNavigationInBackground: Bool = true,
        selectWhenNotFocused: Bool = true,
        allowsExternalBrowserFallback: Bool = true
    ) {
        self.url = url
        self.focus = focus
        self.preferredProfileID = preferredProfileID
        self.chromeVisibility = chromeVisibility
        self.transparentBackground = transparentBackground
        self.bypassRemoteProxy = bypassRemoteProxy
        self.preloadInitialNavigationInBackground = preloadInitialNavigationInBackground
        self.selectWhenNotFocused = selectWhenNotFocused
        self.allowsExternalBrowserFallback = allowsExternalBrowserFallback
    }
}

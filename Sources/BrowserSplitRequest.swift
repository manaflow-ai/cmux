import CmuxBrowser
import Foundation

/// Browser creation options shared by main-workspace and Dock split hosts.
struct BrowserSplitRequest: Sendable {
    nonisolated let url: URL?
    nonisolated let focus: Bool
    nonisolated let preferredProfileID: UUID?
    nonisolated let chromeVisibility: BrowserChromeVisibility
    nonisolated let transparentBackground: Bool
    nonisolated let bypassRemoteProxy: Bool
    nonisolated let preloadInBackground: Bool

    nonisolated init(
        url: URL?,
        focus: Bool,
        preferredProfileID: UUID? = nil,
        chromeVisibility: BrowserChromeVisibility = BrowserChromeVisibility(omnibarVisible: true),
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool = false,
        preloadInBackground: Bool = true
    ) {
        self.url = url
        self.focus = focus
        self.preferredProfileID = preferredProfileID
        self.chromeVisibility = chromeVisibility
        self.transparentBackground = transparentBackground
        self.bypassRemoteProxy = bypassRemoteProxy
        self.preloadInBackground = preloadInBackground
    }
}

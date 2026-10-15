import CmuxBrowser
import Foundation

/// Browser creation options shared by main-workspace and Dock split hosts.
struct BrowserSplitRequest: Sendable {
    let url: URL?
    let focus: Bool
    let preferredProfileID: UUID?
    let chromeVisibility: BrowserChromeVisibility
    let transparentBackground: Bool
    let bypassRemoteProxy: Bool
    /// The engine the request names (`--engine`), or `nil` to follow
    /// `CMUX_BROWSER_ENGINE` and `browser.engine`.
    var engine: BrowserEngineKind? = nil
}

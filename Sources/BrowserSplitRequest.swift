import CmuxBrowser
import Foundation

/// Browser creation options shared by main-workspace and Dock split hosts.
nonisolated struct BrowserSplitRequest: Sendable {
    let url: URL?
    let focus: Bool
    let preferredProfileID: UUID?
    let chromeVisibility: BrowserChromeVisibility
    let transparentBackground: Bool
    let bypassRemoteProxy: Bool
    /// An explicit pane override. `nil` inherits `browser.defaultEngine`.
    let engine: BrowserEngineKind?
}

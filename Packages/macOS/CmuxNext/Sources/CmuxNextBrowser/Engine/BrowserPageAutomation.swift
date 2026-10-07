public import CoreGraphics

/// What page automation needs beyond ``BrowserTab``: an awaited async
/// script (`browser.page.wait`) and the pixels of the whole document
/// (`browser.page.screenshot --full-page`). Each engine's way lives in its
/// own type (`WebKitPageAutomation`, `CEFFullPageCapture`), so the tab
/// types and the protocol do not grow.
@MainActor
public struct BrowserPageAutomation {
    let tab: any BrowserTab

    public init(_ tab: any BrowserTab) {
        self.tab = tab
    }

    /// Runs `body` as an async function in the page world and returns what
    /// it resolves to.
    public func evaluateAsync(_ body: String) async throws -> BrowserJSValue {
        if let webKit = tab as? WebKitTab {
            return try await WebKitPageAutomation(tab: webKit).evaluateAsync(body)
        }
        // Engines whose `evaluate` awaits a returned promise.
        return try await tab.evaluate("(async () => {\n\(body)\n})()", world: .page)
    }

    /// Pixels of the whole document, not only the viewport.
    public func fullPageSnapshot() async throws -> CGImage {
        switch tab {
        case let webKit as WebKitTab: return try await WebKitPageAutomation(tab: webKit).fullPageSnapshot()
        case let cef as CEFTab: return try await CEFFullPageCapture(tab: cef).image()
        default: throw BrowserTabError.snapshotUnavailable
        }
    }
}

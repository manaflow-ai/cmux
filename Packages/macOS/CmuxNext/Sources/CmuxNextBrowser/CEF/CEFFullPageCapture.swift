import CoreGraphics
import Foundation

/// Full-page screenshots of a CEF tab (`browser.page.screenshot
/// --full-page`), kept out of `CEFTab` for its size. Chromium renders beyond
/// the viewport itself, so nothing scrolls.
@MainActor
struct CEFFullPageCapture {
    let tab: CEFTab

    func run() async throws -> CGImage {
        guard let browserID = tab.browserID, !tab.isClosed else { throw BrowserTabError.snapshotUnavailable }
        let runtime = tab.runtime
        let metrics = try await runtime.devTools(browserID, method: "Page.getLayoutMetrics")
        guard let content = await Self.contentSize(metrics),
              BrowserFullPagePlan.isCapturable(contentSize: content) else {
            throw BrowserTabError.unsupported("The page is empty or too large for a full-page screenshot")
        }
        let width = content.width, height = content.height
        let clip: [String: Any] = ["x": 0, "y": 0, "width": width, "height": height, "scale": 1]
        let json = try await runtime.devTools(browserID, method: "Page.captureScreenshot",
                                              params: ["format": "png", "captureBeyondViewport": true, "clip": clip],
                                              timeout: .seconds(18))
        // Decoded off the main actor: a whole page of PNG in base64.
        return try await CEFDevToolsResult.decodedScreenshot(json)
    }

    /// The page's CSS content size from a `Page.getLayoutMetrics` result. The
    /// decode runs off the main actor: the result grows with the page.
    @concurrent nonisolated static func contentSize(_ metrics: String) async -> CGSize? {
        guard let data = metrics.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let size = (object["cssContentSize"] ?? object["contentSize"]) as? [String: Any],
              let width = (size["width"] as? NSNumber)?.doubleValue, let height = (size["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

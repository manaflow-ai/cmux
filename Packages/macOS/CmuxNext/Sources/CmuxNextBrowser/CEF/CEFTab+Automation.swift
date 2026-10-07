import CoreGraphics
import Foundation

/// Full-page screenshots of a Chromium tab (`browser.page.screenshot
/// --full-page`), through ``BrowserPageAutomation``. Chromium renders beyond
/// the viewport itself, so nothing scrolls. A type of its own, so `CEFTab`
/// stays under its line budget.
struct CEFFullPageCapture {
    let tab: CEFTab

    func image() async throws -> CGImage {
        guard let browserID = tab.browserID, !tab.isClosed else { throw BrowserTabError.snapshotUnavailable }
        let runtime = tab.runtime
        let metrics = try await runtime.devTools(browserID, method: "Page.getLayoutMetrics")
        guard let data = metrics.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let size = (object["cssContentSize"] ?? object["contentSize"]) as? [String: Any],
              let width = (size["width"] as? NSNumber)?.doubleValue, let height = (size["height"] as? NSNumber)?.doubleValue,
              BrowserFullPagePlan.isCapturable(contentSize: CGSize(width: width, height: height)) else {
            throw BrowserTabError.unsupported("The page is empty or too large for a full-page screenshot")
        }
        let clip: [String: Any] = ["x": 0, "y": 0, "width": width, "height": height, "scale": 1]
        let json = try await runtime.devTools(browserID, method: "Page.captureScreenshot",
                                              params: ["format": "png", "captureBeyondViewport": true, "clip": clip],
                                              timeout: .seconds(18))
        return try CEFDevToolsResult.screenshot(json)
    }
}

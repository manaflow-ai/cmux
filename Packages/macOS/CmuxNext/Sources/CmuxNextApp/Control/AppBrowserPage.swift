import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Browser page operations (`browser.page.*`, `cmux browser tab_…`) on the page a tab shows,
/// creating the page when the tab was never shown.
enum AppBrowserPage {
    static func run(_ operation: BrowserPageOperation, tabID: String, services: AppServices) async throws -> JSONValue {
        guard let (tab, _) = services.locateTab(tabID) else {
            throw ControlError(code: "not_found", message: "Surface not found or not a browser")
        }
        // The engine the record names, with url/title written back to the record.
        let entry = services.cache.existingBrowser(tabID) ?? services.cache.browser(for: tab)
        guard let page = entry?.tab else {
            throw ControlError(code: "unavailable", message: "The browser page is still starting; retry")
        }
        switch operation {
        case .navigate(let raw):
            let chromium = tab.browserEngine == BrowserEngineTag.cef.rawValue
            guard let target = BrowserURLResolver(allowsChromiumSchemes: chromium).url(for: raw) else {
                throw ControlError(code: "invalid_params", message: "Invalid url: \(raw)")
            }
            page.load(target)
        case .back: page.goBack()
        case .forward: page.goForward()
        case .reload: page.reload()
        case .state:
            return ["url": .string(page.state.url?.absoluteString ?? "about:blank"), "title": .string(page.state.title ?? "")]
        case .evaluate(let script):
            do {
                let value = try await page.evaluate(script)
                return ["value": JSONValue(foundation: value.foundationValue) ?? .null]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        }
        return [:]
    }
}

import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Browser page operations (`browser.page.*`, `cmux browser tab_…`) on the page a tab shows,
/// creating the page when the tab was never shown.
enum AppBrowserPage {
    static func run(_ operation: BrowserPageOperation, tabID: String, services: AppServices) async throws -> CmuxNextSettings.JSONValue {
        guard let (tab, _) = services.locateTab(tabID) else {
            throw ControlError(code: "not_found", message: "Surface not found or not a browser")
        }
        // Before the page exists or any script runs: this tab never gets a
        // saved password filled again, so an automated click cannot release
        // one to page script (plans/cmux-next/browser.md, "Browser import:
        // passwords and security").
        let stale = markAgentDriven(tabID, services: services)
        // The engine the record names, with url/title written back to the record.
        let entry = services.cache.existingBrowser(tabID) ?? services.cache.browser(for: tab)
        guard let page = entry?.tab else {
            throw ControlError(code: "unavailable", message: "The browser page is still starting; retry")
        }
        try rebuildStale(stale, tabID: tabID, for: operation, services: services)
        var target: URL?
        if case .navigate(let raw) = operation {
            let chromium = tab.browserEngine == BrowserEngineTag.cef.rawValue
            guard let resolved = BrowserURLResolver(allowsChromiumSchemes: chromium).url(for: raw) else {
                throw ControlError(code: "invalid_params", message: "Invalid url: \(raw)")
            }
            target = resolved
        }
        if let refusal = agentURLRefusal(operation, target: target, page: page) { throw refusal }
        if let refusal = agentExtensionRefusal(operation, target: target, page: page,
                                               allowedByPerson: services.cache.agentMayUseExtensionTab(tabID), access: .fromDisk) {
            throw refusal
        }
        switch operation {
        case .navigate:
            if let target { page.load(target) }
        case .back: page.goBack()
        case .forward: page.goForward()
        case .reload: page.reload()
        case .state:
            return ["url": .string(page.state.url?.absoluteString ?? "about:blank"), "title": .string(page.state.title ?? "")]
        case .evaluate(let script):
            do {
                let value = try await page.evaluate(script)
                return ["value": CmuxNextSettings.JSONValue(foundation: value.foundationValue) ?? .null]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        }
        return [:]
    }
}

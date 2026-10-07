import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Browser page operations (`browser.page.*`, `cmux browser tab_…`) on the page a tab shows,
/// creating the page when the tab was never shown.
enum AppBrowserPage {
    /// The URL `cmux browser navigate` loads for `raw`, resolved as the
    /// omnibar resolves typed text. The live page decides, not the tab
    /// record (whose engine is nil for a default-engine tab): a Chromium
    /// page opens Chromium's own pages; a WebKit page refuses them by name.
    /// The agent refusals run after this (`agentURLRefusal`). `tabEngine`
    /// (the record's) is deliberately not consulted.
    static func navigationTarget(_ raw: String, tabEngine: String?, page: BrowserEngineKind) -> Result<URL, ControlError> {
        let chromium = page == .cef
        if let resolved = BrowserURLResolver(allowsChromiumSchemes: chromium).url(for: raw) {
            return .success(resolved)
        }
        if !chromium, let chromePage = BrowserURLResolver(allowsChromiumSchemes: true).url(for: raw),
           ChromiumInternalURL.needsChromium(chromePage) {
            return .failure(ControlError(code: "wrong_engine",
                                         message: "\(raw) opens only in a Chromium tab; this tab uses WebKit"))
        }
        return .failure(ControlError(code: "invalid_params", message: "Invalid url: \(raw)"))
    }

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
            target = try navigationTarget(raw, tabEngine: tab.browserEngine, page: page.engineKind).get()
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
            try await ensureBrowser(page)
            do {
                let value = try await page.evaluate(script)
                return ["value": CmuxNextSettings.JSONValue(foundation: value.foundationValue) ?? .null]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        }
        return [:]
    }

    /// A Chromium page has no browser until its pane shows it: a background
    /// tab, a tab `cmux browser open` made without focus, or the page
    /// `rebuildStale` put in place of a stale one. Scripts need the browser,
    /// so it is created in the background (no focus, nothing shown; agents
    /// drive hidden tabs) and awaited. Without this every script on such a
    /// page failed with `js_error` "closed". The control deadline bounds the
    /// wait (`browserCreated` resumes false when the call is cancelled).
    static func ensureBrowser(_ page: any BrowserTab) async throws {
        guard let page = page as? CEFTab, !page.agentRelay.hasBrowser else { return }
        page.agentRelay.createBrowser()
        guard await page.agentRelay.browserCreated() else {
            throw ControlError(code: "unavailable", message: "The browser page could not start; retry")
        }
    }
}

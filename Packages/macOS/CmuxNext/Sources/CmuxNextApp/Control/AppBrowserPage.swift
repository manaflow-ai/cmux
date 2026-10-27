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
        // Chromium makes a page asynchronously: an action right after
        // `cmux browser open` waits for it, bounded (cx-qncg).
        var made = entry?.tab
        if made == nil { made = await awaitPage(tabID, services: services, within: actionWait) }
        guard var page = made else {
            throw ControlError(code: "unavailable", message: "The browser page is still starting; retry")
        }
        // A hibernated tab answers `state` and takes navigation as it is;
        // anything else wakes it in the background and runs on the restored page.
        services.cache.hibernation?.noteAgentUse(tabID)
        if !answersWhileHibernated(operation) {
            guard let live = await awakePage(tabID, page: page, cache: services.cache, within: actionWait) else { throw wakeFailed }
            page = live
        }
        try rebuildStale(stale, tabID: tabID, for: operation, services: services)
        var target: URL?
        if case .navigate(let raw) = operation {
            target = try navigationTarget(raw, tabEngine: tab.browserEngine, page: page.engineKind).get()
        }
        if let refusal = agentURLRefusal(operation, target: target, page: page) { throw refusal }
        if needsLiveBrowser(operation) { try await ensureBrowser(page) }
        // No extension rule here: every agent may drive every tab, in any
        // profile (#24413). The browser's saved passwords never fill in an agent-driven tab
        // (`markAgentDriven` above), and the per-tab lease coordinates agents. The one login an
        // agent tab gets is `browser.page.fill_login`, behind `browser.agentSecureStoreFill` (off
        // by default): only a Secure Store login the person added for that site, only into an
        // agent-profile tab on a site (origin) no agent code has ever run on (here, the browser
        // host's `frame.evaluate`, captures and raw DevTools alike: `PageScriptGate`), and once a
        // site's sign-in is filled, agent code on that site is refused (`BrowserLoginGuards`, one
        // instance, kept across restarts).
        switch operation {
        case .navigate:
            if let target { page.load(target) }
        case .back: page.goBack()
        case .forward: page.goForward()
        case .reload: page.reload()
        case .state:
            return stateResult(page)
        case .evaluate(let script):
            // The page's pending navigation (the first load after open) ends
            // first, bounded; then the script acts on the loaded document.
            _ = await awaitPendingNavigation(page, within: actionWait)
            do {
                let value = try await page.evaluate(script, world: .page, gesture: .agent)
                return ["value": await json(value)]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        case .evaluateIsolated(let script):
            // cmux's own script (the Secure Store fill and its document guard): the isolated world,
            // no user gesture, after the page's first load as `evaluate`.
            _ = await awaitPendingNavigation(page, within: actionWait)
            do {
                let value = try await page.evaluate(script, world: .isolated, gesture: .cmux)
                return ["value": await json(value)]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        case .evaluateAsync(let body):
            do {
                let value = try await page.evaluateAsync(body)
                return ["value": await json(value)]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        case .screenshot(let capture):
            return try await screenshot(page, tabID: tabID, capture)
        case .cookies(let request):
            return try await cookies(page, request)
        case .input(let input):
            // Trusted input after the page's first load, as a script acts on the loaded document.
            _ = await awaitPendingNavigation(page, within: actionWait)
            return try await services.browserNativeInputs.deliver(input, to: page, key: tabID)
        case .upload(let upload):
            // The page's own file chooser takes the files (`BrowserAgentFiles`); a page without one gets them
            // through a page script (the service).
            _ = await awaitPendingNavigation(page, within: actionWait)
            guard let chooser = page as? any BrowserAgentFileChoosing else { return ["chooser": "unsupported"] }
            do {
                let (answer, outcome) = try await chooser.agentFiles.offer(upload.files, within: upload.within, clicking: upload.script, on: page)
                return ["value": await json(answer), "chooser": .string(outcome.code)]
            } catch {
                throw ControlError(code: "js_error", message: String(describing: error))
            }
        }
        return [:]
    }

    /// Whether `operation` needs the page's engine browser, created in the
    /// background for a Chromium tab no pane has shown. A script (a page
    /// wait is an async one: without the browser it ended with "closed"
    /// until the timeout), a capture
    /// (else `snapshotUnavailable` for an agent's tab off screen) and cookies
    /// (Chromium's go through the page's DevTools) do. Input creates it in
    /// ``BrowserNativeInputs``; navigation and `state` do not need it.
    static func needsLiveBrowser(_ operation: BrowserPageOperation) -> Bool {
        switch operation {
        case .evaluate, .evaluateAsync, .evaluateIsolated, .screenshot, .cookies, .upload: true
        case .navigate, .back, .forward, .reload, .state, .input: false
        }
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

import CmuxNextBrowser
import Foundation
import WebKit

extension WebKitDriver {
    func tabsList(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let all = try params.bool("all")
        let tabs = provider?.automationTabs(all: all) ?? []
        return .array(tabs.map { entry in
            var row: [String: DriverJSON] = [
                "targetId": .string(entry.tab.id.rawValue),
                "title": .string(entry.tab.webView.title ?? ""),
                "url": .string(entry.tab.webView.url?.absoluteString ?? "about:blank"),
                "active": .bool(entry.isActive),
                "windowId": .string(entry.windowID),
            ]
            if let opener = entry.openerID { row["openerTargetId"] = .string(opener.rawValue) }
            return .object(row)
        })
    }

    func tabsOpen(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        guard let provider else { throw DriverError(.closed, "tabs.open: the browser is gone") }
        let raw = try params.optionalString("url")
        let url = try raw.map { raw throws(DriverError) in try Self.navigableURL(raw, method: "tabs.open") }
        let tab: WebKitTab
        do {
            tab = try await provider.openAutomationTab(url: nil)
        } catch {
            throw DriverError(.unsupported, "tabs.open: \(error.localizedDescription)")
        }
        let session = session(for: tab)
        if let url {
            let ticket = session.waits.beginNavigation(requestedURL: url) { tab.startLoad(url) }
            do {
                try await session.waits.reach(.commit, for: ticket, timeout: try params.timeout(), what: "tabs.open")
            } catch {
                // The host never learns this tab's id, so it may not stay open.
                tabClosedByDriver(tab)
                throw error
            }
        }
        return .object(["targetId": .string(tab.id.rawValue)])
    }

    func tabsClose(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        tabClosedByDriver(tab)
        return .null
    }

    private func tabClosedByDriver(_ tab: WebKitTab) {
        AgentWorld.uninstall(from: tab.webView.configuration.userContentController)
        tabClosed(tab.id)
        provider?.closeAutomationTab(tab.id)
    }

    /// An absolute URL with a scheme; a bare host gets https, as the
    /// runtime's checkNavigableURL allows.
    static func navigableURL(_ raw: String, method: String) throws(DriverError) -> URL {
        if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty { return url }
        if let url = URL(string: "https://\(raw)"), url.host != nil { return url }
        throw DriverError(.invalid, "\(method): Cannot navigate to invalid URL \(raw)")
    }

    /// Selecting a tab changes the user's view, so the host passes it only
    /// for origin `user` or `focus: true`.
    func tabsActivate(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        provider?.activateAutomationTab(tab.id)
        return .null
    }

    /// Answers from native state, so it works while a JavaScript dialog
    /// blocks page script.
    func tabInfo(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let webView = tab.webView
        let scale = webView.pageZoom * webView.magnification
        let width = webView.bounds.width / (scale > 0 ? scale : 1)
        let height = webView.bounds.height / (scale > 0 ? scale : 1)
        let loadState = webView.isLoading ? (session.waits.state ?? .commit) : .load
        return .object([
            "url": .string(webView.url?.absoluteString ?? "about:blank"),
            "title": .string(webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? session.lastTitle ?? ""),
            "loadState": .string(loadState.name),
            "viewport": .object(["width": .number(width.rounded()), "height": .number(height.rounded())]),
            "deviceScaleFactor": .number(Double(webView.window?.backingScaleFactor ?? 2)),
        ])
    }

    func tabNavigate(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let raw = try params.string("url")
        let url = try Self.navigableURL(raw, method: "tab.navigate")
        let until = LoadState(name: try params.optionalString("waitUntil") ?? "load") ?? .load
        let ticket = session.waits.beginNavigation(requestedURL: url) { tab.startLoad(url) }
        try await session.waits.reach(until, for: ticket, timeout: try params.timeout(), what: "page.goto")
        return .object(["url": .string(tab.webView.url?.absoluteString ?? raw)])
    }

    func tabHistory(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let delta = try params.number("delta")
        let list = tab.webView.backForwardList
        guard let item = delta < 0 ? list.backItem : list.forwardItem else { return .null }
        // The blank page a tab opened on is not an entry to go back to.
        if delta < 0, list.backList.count == 1, item.url.absoluteString == "about:blank" { return .null }
        let until = LoadState(name: try params.optionalString("waitUntil") ?? "load") ?? .load
        let ticket = session.waits.beginNavigation { delta < 0 ? tab.startGoBack() : tab.startGoForward() }
        try await session.waits.reach(until, for: ticket, timeout: try params.timeout(), what: delta < 0 ? "page.goBack" : "page.goForward")
        return .object(["url": .string(tab.webView.url?.absoluteString ?? "")])
    }

    func tabReload(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let until = LoadState(name: try params.optionalString("waitUntil") ?? "load") ?? .load
        let ticket = session.waits.beginNavigation { tab.startReload() }
        try await session.waits.reach(until, for: ticket, timeout: try params.timeout(), what: "page.reload")
        return .object([:])
    }

    func cookiesGet(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let store = try anyTab(params).webView.configuration.websiteDataStore.httpCookieStore
        let urls = try params.strings("urls").compactMap(URL.init(string:))
        let cookies = await store.allCookies()
        return .array(cookies.filter { cookie in urls.isEmpty || urls.contains { Self.cookie(cookie, matches: $0) } }.map(Self.json))
    }

    func cookiesClear(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let store = try anyTab(params).webView.configuration.websiteDataStore.httpCookieStore
        for cookie in await store.allCookies() { await store.deleteCookie(cookie) }
        return .null
    }

    /// Cookie calls have no target; the session's first tab names the profile.
    private func anyTab(_ params: DriverParams) throws(DriverError) -> WebKitTab {
        if params.has("targetId") { return try target(params).0 }
        guard let tab = provider?.automationTabs(all: false).first?.tab else {
            throw DriverError(.notFound, "\(params.method): no tab to read cookies from")
        }
        return tab
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    private static func json(_ cookie: HTTPCookie) -> DriverJSON {
        var row: [String: DriverJSON] = [
            "name": .string(cookie.name), "value": .string(cookie.value), "domain": .string(cookie.domain),
            "path": .string(cookie.path), "httpOnly": .bool(cookie.isHTTPOnly), "secure": .bool(cookie.isSecure),
            "expires": .number(cookie.expiresDate.map { $0.timeIntervalSince1970 } ?? -1),
        ]
        if let sameSite = cookie.sameSitePolicy?.rawValue { row["sameSite"] = .string(sameSite.capitalized) }
        return .object(row)
    }
}

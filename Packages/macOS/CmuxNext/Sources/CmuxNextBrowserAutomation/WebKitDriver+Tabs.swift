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
        let url = try params.optionalString("url").flatMap(URL.init(string:))
        let tab: WebKitTab
        do {
            tab = try await provider.openAutomationTab(url: nil)
        } catch {
            throw DriverError(.unsupported, "tabs.open: \(error.localizedDescription)")
        }
        let session = session(for: tab)
        if let url {
            let generation = session.waits.beginNavigation()
            tab.load(url)
            try await session.waits.reach(.commit, after: generation, timeout: try params.timeout(), what: "tabs.open")
        }
        return .object(["targetId": .string(tab.id.rawValue)])
    }

    func tabsClose(_ params: DriverParams) throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        session.waits.failAll(DriverError(.closed, "Target page, context or browser has been closed"))
        sessions[tab.id] = nil
        provider?.closeAutomationTab(tab.id)
        emit("tab.closed", ["targetId": .string(tab.id.rawValue)])
        return .null
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
        guard let url = URL(string: raw) ?? URL(string: "https://\(raw)") else {
            throw DriverError(.invalid, "tab.navigate: Cannot navigate to invalid URL \(raw)")
        }
        let until = LoadState(name: try params.optionalString("waitUntil") ?? "load") ?? .load
        let generation = session.waits.beginNavigation()
        tab.load(url)
        try await session.waits.reach(until, after: generation, timeout: try params.timeout(), what: "page.goto")
        return .object(["url": .string(tab.webView.url?.absoluteString ?? raw)])
    }

    func tabHistory(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let delta = try params.number("delta")
        let list = tab.webView.backForwardList
        guard (delta < 0 ? list.backItem : list.forwardItem) != nil else { return .null }
        let until = LoadState(name: try params.optionalString("waitUntil") ?? "load") ?? .load
        let generation = session.waits.beginNavigation()
        if delta < 0 { tab.goBack() } else { tab.goForward() }
        try await session.waits.reach(until, after: generation, timeout: try params.timeout(), what: delta < 0 ? "page.goBack" : "page.goForward")
        return .object(["url": .string(tab.webView.url?.absoluteString ?? "")])
    }

    func tabReload(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let until = LoadState(name: try params.optionalString("waitUntil") ?? "load") ?? .load
        let generation = session.waits.beginNavigation()
        tab.reload()
        try await session.waits.reach(until, after: generation, timeout: try params.timeout(), what: "page.reload")
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
        return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path)
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

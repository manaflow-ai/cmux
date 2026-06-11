import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import WebKit

/// The live-app half of the v2 browser cookies/storage/tabs/state domain
/// (the resolved-panel script runner, cookie-store reach, tab management,
/// `browser.state.save`/`load`, and the unsupported-network bookkeeping).
/// Split out of `+ControlBrowserContext.swift` for the file-length budget.
extension TerminalController {
    // MARK: - Resolved-panel script execution

    /// Re-fetches the resolved surface's browser panel (the resolved ids cross
    /// the seam; the panel is re-looked-up per reach, as the automation
    /// witnesses do).
    private func browserContextPanel(surfaceID: UUID) -> BrowserPanel? {
        guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
            return nil
        }
        return workspace.browserPanel(for: surfaceID)
    }

    /// The resolved-or-failed panel reach shared by the witnesses below.
    private enum BrowserContextResolution {
        case failure(ControlBrowserPanelFailure)
        case success(identity: ControlBrowserPanelIdentity, panel: BrowserPanel)
    }

    /// Maps the shared panel-resolution ladder onto the seam failure cases.
    private func browserContextResolve(
        _ target: ControlBrowserSurfaceTarget
    ) -> BrowserContextResolution {
        switch controlBrowserResolvePanel(routing: target.routing, surfaceID: target.surfaceID) {
        case .tabManagerUnavailable:
            return .failure(.tabManagerUnavailable)
        case .workspaceNotFound:
            return .failure(.workspaceNotFound)
        case .paneNotFound(let paneID):
            return .failure(.paneNotFound(paneID: paneID))
        case .paneHasNoSelectedSurface(let paneID):
            return .failure(.paneHasNoSelectedSurface(paneID: paneID))
        case .noFocusedBrowserSurface:
            return .failure(.noFocusedBrowserSurface)
        case .surfaceNotBrowser(let surfaceID):
            return .failure(.surfaceNotBrowser(surfaceID: surfaceID))
        case .resolved(let workspaceID, let surfaceID):
            guard let panel = browserContextPanel(surfaceID: surfaceID) else {
                return .failure(.surfaceNotBrowser(surfaceID: surfaceID))
            }
            return .success(
                identity: ControlBrowserPanelIdentity(workspaceID: workspaceID, surfaceID: surfaceID),
                panel: panel
            )
        }
    }

    /// Bridges a legacy JS run result onto the seam outcome (top-level
    /// `undefined` sentinel, then `v2NormalizeJSValue`, then the lossless
    /// `JSONValue` bridge).
    private func browserContextScriptOutcome(
        _ result: V2JavaScriptResult
    ) -> ControlBrowserScriptResolution.Outcome {
        switch result {
        case .failure(let message):
            return .jsError(message)
        case .success(let value):
            if value is V2BrowserUndefinedSentinel {
                return .undefined
            }
            return .value(JSONValue(foundationObject: v2NormalizeJSValue(value)) ?? .null)
        }
    }

    func controlBrowserRunScript(
        target: ControlBrowserSurfaceTarget,
        script: String,
        timeout: Double,
        mode: ControlBrowserScriptMode
    ) -> ControlBrowserScriptResolution {
        switch browserContextResolve(target) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let identity, let panel):
            let result: V2JavaScriptResult
            switch mode {
            case .frameAware(let useEval):
                result = v2RunBrowserJavaScript(
                    panel.webView,
                    surfaceId: identity.surfaceID,
                    script: script,
                    timeout: timeout,
                    useEval: useEval
                )
            case .pageWorld(let installTelemetryHooks):
                if installTelemetryHooks {
                    _ = v2RunJavaScript(
                        panel.webView,
                        script: BrowserPanel.telemetryHookBootstrapScriptSource,
                        timeout: 5.0,
                        contentWorld: .page
                    )
                }
                result = v2RunJavaScript(
                    panel.webView,
                    script: script,
                    timeout: timeout,
                    contentWorld: .page
                )
            }
            return .resolved(identity: identity, outcome: browserContextScriptOutcome(result))
        }
    }

    // MARK: - Cookie store reach (the legacy v2BrowserCookieStore* helpers)

    /// The legacy `v2BrowserCookieStoreAll` (run-loop pumping wait).
    private func browserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            store.getAllCookies { items in
                finish(items)
            }
        }
    }

    /// The legacy `v2BrowserCookieStoreSet`.
    private func browserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.setCookie(cookie) {
                finish(true)
            }
        } ?? false
    }

    /// The legacy `v2BrowserCookieStoreDelete`.
    private func browserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            store.delete(cookie) {
                finish(true)
            }
        } ?? false
    }

    /// The legacy `v2BrowserCookieFromObject`.
    private func browserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    /// Bridges an `HTTPCookie` to the Sendable seam snapshot (the legacy
    /// `v2BrowserCookieDict` fields).
    private func browserCookieSnapshot(_ cookie: HTTPCookie) -> ControlBrowserCookie {
        ControlBrowserCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            isSecure: cookie.isSecure,
            isSessionOnly: cookie.isSessionOnly,
            expiresEpoch: cookie.expiresDate.map { Int64(Int($0.timeIntervalSince1970)) }
        )
    }

    // MARK: - cookies

    func controlBrowserCookiesGet(
        target: ControlBrowserSurfaceTarget
    ) -> ControlBrowserCookiesGetResolution {
        switch browserContextResolve(target) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let identity, let panel):
            let store = panel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = browserCookieStoreAll(store) else {
                return .timedOut
            }
            return .cookies(identity: identity, cookies: cookies.map(browserCookieSnapshot))
        }
    }

    func controlBrowserCookiesSet(
        target: ControlBrowserSurfaceTarget,
        rows: [JSONValue]
    ) -> ControlBrowserCookiesSetResolution {
        switch browserContextResolve(target) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let identity, let panel):
            guard !rows.isEmpty else {
                return .emptyPayload
            }
            let store = panel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = panel.currentURL
            var setCount = 0
            for row in rows {
                guard let raw = row.foundationObject as? [String: Any],
                      let cookie = browserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .invalidCookie(row: row)
                }
                if browserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .timedOutSetting(name: cookie.name)
                }
            }
            return .set(identity: identity, count: setCount)
        }
    }

    func controlBrowserCookiesClear(
        target: ControlBrowserSurfaceTarget,
        name: String?,
        domain: String?,
        hasAllParam: Bool
    ) -> ControlBrowserCookiesClearResolution {
        switch browserContextResolve(target) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let identity, let panel):
            let store = panel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = browserCookieStoreAll(store) else {
                return .timedOut
            }
            let clearAll = !hasAllParam && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }
            var removed = 0
            for cookie in targets where browserCookieStoreDelete(store, cookie: cookie) {
                removed += 1
            }
            return .cleared(identity: identity, removed: removed)
        }
    }

    // MARK: - state save / load

    func controlBrowserStateCapture(
        target: ControlBrowserSurfaceTarget,
        storageScript: String
    ) -> ControlBrowserStateCaptureResolution {
        switch browserContextResolve(target) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let identity, let panel):
            let storageValue: JSONValue
            switch v2RunBrowserJavaScript(
                panel.webView,
                surfaceId: identity.surfaceID,
                script: storageScript,
                timeout: 10.0
            ) {
            case .failure(let message):
                return .jsError(message)
            case .success(let value):
                storageValue = JSONValue(foundationObject: v2NormalizeJSValue(value)) ?? .null
            }

            let store = panel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (browserCookieStoreAll(store) ?? []).map(browserCookieSnapshot)

            return .captured(ControlBrowserStateCapture(
                identity: identity,
                storage: storageValue,
                cookies: cookies,
                url: panel.currentURL?.absoluteString ?? "",
                frameSelector: controlBrowserAutomationState.frameSelector(forSurface: identity.surfaceID)
            ))
        }
    }

    func controlBrowserStateApply(
        target: ControlBrowserSurfaceTarget,
        frameSelector: String?,
        navigateToURLString: String?,
        cookieRows: [JSONValue],
        storageScript: String?
    ) -> ControlBrowserStateApplyResolution {
        switch browserContextResolve(target) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let identity, let panel):
            let surfaceID = identity.surfaceID
            controlBrowserAutomationState.setFrameSelector(frameSelector, forSurface: surfaceID)

            if let navigateToURLString, let parsed = URL(string: navigateToURLString) {
                panel.navigate(to: parsed)
            }

            if !cookieRows.isEmpty {
                let store = panel.webView.configuration.websiteDataStore.httpCookieStore
                for row in cookieRows {
                    if let raw = row.foundationObject as? [String: Any],
                       let cookie = browserCookieFromObject(raw, fallbackURL: panel.currentURL) {
                        _ = browserCookieStoreSet(store, cookie: cookie)
                    }
                }
            }

            if let storageScript {
                _ = v2RunBrowserJavaScript(
                    panel.webView,
                    surfaceId: surfaceID,
                    script: storageScript,
                    timeout: 10.0
                )
            }

            return .applied(identity: identity)
        }
    }

    // MARK: - tabs

    func controlBrowserTabList(routing: ControlRoutingSelectors) -> ControlBrowserTabListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }
        let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
            panel as? BrowserPanel
        }
        let tabs = browserPanels.map { panel in
            ControlBrowserTabSummary(
                surfaceID: panel.id,
                title: panel.displayTitle,
                url: panel.currentURL?.absoluteString ?? "",
                isFocused: panel.id == ws.focusedPanelId,
                paneID: ws.paneId(forPanelId: panel.id)?.id
            )
        }
        return ControlBrowserTabListSnapshot(
            workspaceID: ws.id,
            focusedSurfaceID: ws.focusedPanelId,
            tabs: tabs
        )
    }

    func controlBrowserTabNew(
        routing: ControlRoutingSelectors,
        urlString: String?,
        explicitPaneID: UUID?,
        paneFromSurfaceID: UUID?
    ) -> ControlBrowserTabNewResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let url = urlString.flatMap(URL.init(string:))
        let paneUUID = explicitPaneID
            ?? (paneFromSurfaceID.flatMap { ws.paneId(forPanelId: $0)?.id })
            ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
            ?? ws.bonsplitController.focusedPaneId?.id
        guard let paneUUID,
              let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
            return .paneNotFound
        }

        guard let panel = ws.newBrowserSurface(
            inPane: pane,
            url: url,
            focus: true,
            creationPolicy: .automationPreload
        ) else {
            return .createFailed
        }
        return .created(
            workspaceID: ws.id,
            paneID: pane.id,
            surfaceID: panel.id,
            url: panel.currentURL?.absoluteString ?? ""
        )
    }

    func controlBrowserTabSwitch(
        routing: ControlRoutingSelectors,
        explicitID: UUID?,
        index: Int?,
        surfaceID: UUID?
    ) -> ControlBrowserTabSwitchResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
            (panel as? BrowserPanel)?.id
        }
        let targetId: UUID? = {
            if let explicitID {
                return explicitID
            }
            if let index, index >= 0, index < browserIds.count {
                return browserIds[index]
            }
            return surfaceID
        }()
        guard let targetId, browserIds.contains(targetId) else {
            return .tabNotFound
        }
        ws.focusPanel(targetId)
        return .switched(workspaceID: ws.id, surfaceID: targetId)
    }

    func controlBrowserTabClose(
        routing: ControlRoutingSelectors,
        explicitID: UUID?,
        index: Int?,
        surfaceID: UUID?
    ) -> ControlBrowserTabCloseResolution {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
            (panel as? BrowserPanel)?.id
        }
        guard !browserIds.isEmpty else {
            return .noBrowserTabs
        }
        let targetId: UUID? = {
            if let explicitID {
                return explicitID
            }
            if let index, index >= 0, index < browserIds.count {
                return browserIds[index]
            }
            if let surfaceID {
                return surfaceID
            }
            return ws.focusedPanelId
        }()
        guard let targetId, browserIds.contains(targetId) else {
            return .tabNotFound
        }
        if ws.panels.count <= 1 {
            return .lastSurface
        }
        guard closeSurfaceRecordingHistory(in: ws, surfaceId: targetId, force: true) else {
            return .closeFailed(surfaceID: targetId)
        }
        return .closed(workspaceID: ws.id, surfaceID: targetId)
    }

    // MARK: - unsupported-network bookkeeping

    func controlBrowserRecordUnsupportedRequest(surfaceID: UUID, request: JSONValue) {
        var logs = browserUnsupportedNetworkRequestsBySurface[surfaceID] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        browserUnsupportedNetworkRequestsBySurface[surfaceID] = logs
    }

    func controlBrowserUnsupportedRequests(surfaceID: UUID) -> [JSONValue] {
        browserUnsupportedNetworkRequestsBySurface[surfaceID] ?? []
    }
}

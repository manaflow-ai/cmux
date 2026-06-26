import AppKit
import CmuxControlSocket
import Foundation
import WebKit

/// The live-app half of the non-JS-evaluating, main-actor `browser.cookies.*`
/// and `browser.storage.*` commands. The coordinator owns the param parsing and
/// `JSONValue` payload shaping; these witnesses perform the `TabManager` /
/// `Workspace` / `BrowserPanel` reach plus the `WKHTTPCookieStore` and storage
/// JS work, byte-faithful to the former `v2BrowserCookies*` / `v2BrowserStorage*`
/// bodies. The shared `v2BrowserWithPanel`-head resolution is reproduced by
/// `browserResolvePanelTyped(params:)`, which surfaces each failure category as
/// a typed value the coordinator maps back to the exact legacy `.err`.
///
/// The per-surface caches (frame selector, init scripts/styles, dialog queue,
/// download events, not-supported network log) live in `v2BrowserSurfaceState`
/// (a `BrowserAutomationSurfaceState` in `CmuxBrowser`) owned by
/// `TerminalController`: the JS-evaluating worker-lane methods (`browser.snapshot`
/// and friends) read the frame-selector cache through
/// `v2BrowserCurrentFrameSelector`, so it cannot move into the `@MainActor`
/// coordinator without breaking that out-of-scope reader.
extension TerminalController {
    /// `[String: JSONValue]` → the Foundation `[String: Any]` the legacy
    /// `v2*` param helpers and resolvers consume (the same bridge the mobile-host
    /// witnesses use).
    private func browserFoundationParams(_ params: [String: JSONValue]) -> [String: Any] {
        params.mapValues(\.foundationObject)
    }

    /// A resolved browser panel for a cookies/storage command.
    struct ResolvedBrowserPanel {
        let workspace: Workspace
        let surfaceId: UUID
        let browserPanel: BrowserPanel
    }

    /// The resolved browser panel (or the typed failure category) for a
    /// cookies/storage command.
    enum BrowserPanelResolution {
        case failure(ControlBrowserPanelResolutionFailure)
        case success(ResolvedBrowserPanel)
    }

    /// The resolved browser panel for a cookies/storage command, or the typed
    /// failure category. Reproduces the `v2BrowserWithPanel` head exactly
    /// (`v2ResolveTabManager` → `v2ResolveWorkspace` → `v2ResolveBrowserSurfaceId`
    /// → `Workspace.browserPanel(for:)`), all on the main actor.
    ///
    /// `internal` (not `private`): the addscript/addstyle/addinitscript/dialog
    /// witnesses in `TerminalController.swift` share the same `v2BrowserWithPanel`
    /// head and reuse this resolver.
    func browserResolvePanelTyped(
        params: [String: Any]
    ) -> BrowserPanelResolution {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .failure(.tabManagerUnavailable)
        }
        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .failure(.workspaceNotFound)
        }
        // The legacy `v2ResolveBrowserSurfaceId` returns either a surface id or an
        // `.err`; re-derive its failure category from the same inputs.
        if v2UUID(params, "surface_id") == nil, v2UUID(params, "tab_id") == nil,
           let paneId = v2UUID(params, "pane_id") {
            guard let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return .failure(.paneNotFound(paneID: paneId))
            }
            guard ws.bonsplitController.selectedTab(inPane: pane) != nil,
                  let selectedTab = ws.bonsplitController.selectedTab(inPane: pane),
                  ws.panelIdFromSurfaceId(selectedTab.id) != nil else {
                return .failure(.paneHasNoSelectedSurface(paneID: paneId))
            }
        }
        let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
        // A non-nil error here is already covered by the pane checks above; fall
        // through on its surface id.
        guard let surfaceId = resolvedSurface.surfaceId else {
            return .failure(.noFocusedBrowserSurface)
        }
        guard let browserPanel = ws.browserPanel(for: surfaceId) else {
            return .failure(.surfaceNotBrowser(surfaceID: surfaceId))
        }
        return .success(ResolvedBrowserPanel(workspace: ws, surfaceId: surfaceId, browserPanel: browserPanel))
    }
}

// The `ControlBrowserContext` conformance is declared in
// `TerminalController+ControlBrowserContext.swift`; these are the additional
// cookies/storage witnesses on the same type.
extension TerminalController {
    // MARK: - cookies.get

    func controlBrowserCookiesGet(
        params: [String: JSONValue],
        nameFilter: String?,
        domainFilter: String?,
        pathFilter: String?
    ) -> ControlBrowserCookiesGetResolution {
        let foundation = browserFoundationParams(params)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let store = resolved.browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .timedOut
            }
            if let nameFilter {
                cookies = cookies.filter { $0.name == nameFilter }
            }
            if let domainFilter {
                cookies = cookies.filter { $0.domain.contains(domainFilter) }
            }
            if let pathFilter {
                cookies = cookies.filter { $0.path == pathFilter }
            }
            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                cookies: cookies.map(controlBrowserCookie)
            )
        }
    }

    // MARK: - cookies.set

    func controlBrowserCookiesSet(
        params: [String: JSONValue],
        cookieRows: [JSONValue]
    ) -> ControlBrowserCookiesSetResolution {
        let foundation = browserFoundationParams(params)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            guard !cookieRows.isEmpty else {
                return .missingPayload
            }
            let store = resolved.browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = resolved.browserPanel.currentURL
            var setCount = 0
            for row in cookieRows {
                guard case .object = row,
                      let raw = row.foundationObject as? [String: Any],
                      let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .invalidCookie(row: row)
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .timedOut(cookieName: cookie.name)
                }
            }
            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                setCount: setCount
            )
        }
    }

    // MARK: - cookies.clear

    func controlBrowserCookiesClear(
        params: [String: JSONValue],
        nameFilter: String?,
        domainFilter: String?,
        clearAll: Bool
    ) -> ControlBrowserCookiesClearResolution {
        let foundation = browserFoundationParams(params)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let store = resolved.browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .timedOut
            }
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let nameFilter, cookie.name != nameFilter { return false }
                if let domainFilter, !cookie.domain.contains(domainFilter) { return false }
                return true
            }
            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }
            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: resolved.surfaceId,
                cleared: removed
            )
        }
    }

    /// The cookie wire value, the typed twin of `v2BrowserCookieDict(_:)`.
    private func controlBrowserCookie(_ cookie: HTTPCookie) -> ControlBrowserCookie {
        ControlBrowserCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            secure: cookie.isSecure,
            sessionOnly: cookie.isSessionOnly,
            expires: cookie.expiresDate.map { Int($0.timeIntervalSince1970) }
        )
    }

    // MARK: - storage.get

    func controlBrowserStorageGet(
        params: [String: JSONValue],
        key: String?
    ) -> ControlBrowserStorageGetResolution {
        let foundation = browserFoundationParams(params)
        let storageType = v2BrowserStorageType(foundation)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let script = v2BrowserControl.storageGetScript(storageType: storageType, key: key)
            switch v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool, ok else {
                    return .unavailable(storageType: storageType)
                }
                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: resolved.surfaceId,
                    storageType: storageType,
                    key: key,
                    value: JSONValue(foundationObject: v2NormalizeJSValue(dict["value"])) ?? .null
                )
            }
        }
    }

    // MARK: - storage.set

    func controlBrowserStorageSet(
        params: [String: JSONValue],
        key: String,
        value: JSONValue
    ) -> ControlBrowserStorageSetResolution {
        let foundation = browserFoundationParams(params)
        let storageType = v2BrowserStorageType(foundation)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value.foundationObject))
            let script = v2BrowserControl.storageSetScript(storageType: storageType, key: key, valueLiteral: valueLiteral)
            switch v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let result):
                guard let dict = result as? [String: Any],
                      let ok = dict["ok"] as? Bool, ok else {
                    return .unavailable(storageType: storageType)
                }
                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: resolved.surfaceId,
                    storageType: storageType,
                    key: key
                )
            }
        }
    }

    // MARK: - storage.clear

    func controlBrowserStorageClear(
        params: [String: JSONValue]
    ) -> ControlBrowserStorageClearResolution {
        let foundation = browserFoundationParams(params)
        let storageType = v2BrowserStorageType(foundation)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let script = v2BrowserControl.storageClearScript(storageType: storageType)
            switch v2RunBrowserJavaScript(resolved.browserPanel.webView, surfaceId: resolved.surfaceId, script: script) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool, ok else {
                    return .unavailable(storageType: storageType)
                }
                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: resolved.surfaceId,
                    storageType: storageType
                )
            }
        }
    }
}

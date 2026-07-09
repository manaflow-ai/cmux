internal import Foundation

/// The non-JS-evaluating, main-actor `browser.cookies.*` and `browser.storage.*`
/// commands, lifted byte-faithfully from the former
/// `TerminalController.v2BrowserCookies*` / `v2BrowserStorage*` bodies.
///
/// The coordinator owns the param parsing/validation and builds each payload
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries the `v2BrowserWithPanel` bodies returned). The app-coupled work
/// (panel resolution, `WKHTTPCookieStore` reads/writes, the storage JS eval, and
/// the app-side `BrowserControlService.storageType(params:)`) runs behind the
/// ``ControlBrowserContext`` seam and returns a typed Sendable resolution.
///
/// Cookies and storage run on the main actor (they do not block on page JS the
/// way `browser.navigate`/`browser.eval` do; the storage JS is a short
/// synchronous read/write hop), so the `@MainActor` coordinator can host them.
extension ControlCommandCoordinator {
    /// The browser-domain view of the seam (the cross-file twin of the
    /// same-file `browserContext`; bound through a local first so the downcast
    /// is not a warning-triggering downcast-of-an-optional).
    private var cookiesStorageContext: (any ControlBrowserContext)? {
        context
    }

    /// Maps a shared panel-resolution failure to the exact legacy `.err` the
    /// `v2BrowserWithPanel` head produced.
    ///
    /// `internal` (not `private`): the read-only-getters domain
    /// (`ControlCommandCoordinator+BrowserReadOnly.swift`) shares the same
    /// `v2BrowserWithPanel` head and reuses this mapping.
    func browserPanelResolutionError(
        _ failure: ControlBrowserPanelResolutionFailure
    ) -> ControlCallResult {
        switch failure {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .paneNotFound(let paneID):
            return .err(
                code: "not_found",
                message: "Pane not found",
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
        case .paneHasNoSelectedSurface(let paneID):
            return .err(
                code: "not_found",
                message: "Pane has no selected surface",
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
        case .noFocusedBrowserSurface:
            return .err(code: "not_found", message: "No focused browser surface", data: nil)
        case .surfaceNotBrowser(let surfaceID):
            return .err(
                code: "invalid_params",
                message: "Surface is not a browser",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        }
    }

    /// The standard `workspace_id`/`workspace_ref`/`surface_id`/`surface_ref`
    /// identity object every `v2BrowserWithPanel` payload opened with, plus the
    /// command's extra keys (insertion order is irrelevant for JSON objects).
    ///
    /// `internal` (not `private`): the read-only-getters domain
    /// (`ControlCommandCoordinator+BrowserReadOnly.swift`) reuses this identity
    /// payload shaping.
    func browserPanelPayload(
        workspaceID: UUID,
        surfaceID: UUID,
        extra: [String: JSONValue]
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": ref(.surface, surfaceID),
        ]
        for (key, value) in extra { payload[key] = value }
        return .object(payload)
    }

    /// One cookie as its byte-identical wire object (the legacy
    /// `v2BrowserCookieDict` shape).
    private func cookieValue(_ cookie: ControlBrowserCookie) -> JSONValue {
        .object([
            "name": .string(cookie.name),
            "value": .string(cookie.value),
            "domain": .string(cookie.domain),
            "path": .string(cookie.path),
            "secure": .bool(cookie.secure),
            "session_only": .bool(cookie.sessionOnly),
            "expires": cookie.expires.map { .int(Int64($0)) } ?? .null,
        ])
    }

    // MARK: - cookies.get

    func browserCookiesGet(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = cookiesStorageContext?.controlBrowserCookiesGet(
            params: params,
            nameFilter: string(params, "name"),
            domainFilter: string(params, "domain"),
            pathFilter: string(params, "path")
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .timedOut:
            return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
        case .resolved(let workspaceID, let surfaceID, let cookies):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["cookies": .array(cookies.map(cookieValue))]
            ))
        }
    }

    // MARK: - cookies.set

    func browserCookiesSet(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = cookiesStorageContext?.controlBrowserCookiesSet(
            params: params,
            cookieRows: cookieRows(params)
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .missingPayload:
            return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
        case .invalidCookie(let row):
            return .err(
                code: "invalid_params",
                message: "Invalid cookie payload",
                data: .object(["cookie": row])
            )
        case .timedOut(let cookieName):
            return .err(
                code: "timeout",
                message: "Timed out setting cookie",
                data: .object(["name": .string(cookieName)])
            )
        case .resolved(let workspaceID, let surfaceID, let setCount):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["set": .int(Int64(setCount))]
            ))
        }
    }

    /// Reconstructs the cookie rows the legacy body fed to
    /// `v2BrowserCookieFromObject`: the `cookies` array verbatim when present,
    /// else a single cookie assembled from the individual params (only when at
    /// least one of them is present, matching the legacy `!single.isEmpty`
    /// guard). An empty result reaches the witness as the "Missing cookies
    /// payload" case.
    private func cookieRows(_ params: [String: JSONValue]) -> [JSONValue] {
        if case .array(let rows)? = params["cookies"] {
            // Legacy: `params["cookies"] as? [[String: Any]]` — only object
            // rows count; a non-object element makes the cast fail wholesale.
            if rows.allSatisfy({ if case .object = $0 { return true } else { return false } }) {
                return rows
            }
        }
        var single: [String: JSONValue] = [:]
        if let name = string(params, "name") { single["name"] = .string(name) }
        if let value = string(params, "value") { single["value"] = .string(value) }
        if let url = string(params, "url") { single["url"] = .string(url) }
        if let domain = string(params, "domain") { single["domain"] = .string(domain) }
        if let path = string(params, "path") { single["path"] = .string(path) }
        if let secure = bool(params, "secure") { single["secure"] = .bool(secure) }
        if let expires = int(params, "expires") { single["expires"] = .int(Int64(expires)) }
        return single.isEmpty ? [] : [.object(single)]
    }

    // MARK: - cookies.clear

    func browserCookiesClear(_ params: [String: JSONValue]) -> ControlCallResult {
        let name = string(params, "name")
        let domain = string(params, "domain")
        // Legacy: `params["all"] == nil && name == nil && domain == nil`. The
        // presence of an `all` key (any value, even null/false) defeats the
        // clear-everything default, matching `params["all"] == nil`.
        let clearAll = params["all"] == nil && name == nil && domain == nil
        let resolution = cookiesStorageContext?.controlBrowserCookiesClear(
            params: params,
            nameFilter: name,
            domainFilter: domain,
            clearAll: clearAll
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .timedOut:
            return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
        case .resolved(let workspaceID, let surfaceID, let cleared):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["cleared": .int(Int64(cleared))]
            ))
        }
    }

    // MARK: - storage.get

    func browserStorageGet(_ params: [String: JSONValue]) -> ControlCallResult {
        let key = string(params, "key")
        let resolution = cookiesStorageContext?.controlBrowserStorageGet(
            params: params,
            key: key
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .unavailable(let storageType):
            return .err(
                code: "invalid_state",
                message: "Storage unavailable",
                data: .object(["type": .string(storageType)])
            )
        case .resolved(let workspaceID, let surfaceID, let storageType, let resolvedKey, let value):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "type": .string(storageType),
                    "key": orNull(resolvedKey),
                    "value": value,
                ]
            ))
        }
    }

    // MARK: - storage.set

    func browserStorageSet(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: `Missing key` / `Missing value` are checked before the panel
        // resolution (the `storageType` is also computed first, but it has no
        // observable effect until the resolved path, which echoes it).
        guard let key = string(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        // Legacy: `guard let value = params["value"]` — a present `value` key,
        // even JSON `null`, passes (it becomes `NSNull` in the Foundation
        // payload); only an ABSENT key is "Missing value".
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        let resolution = cookiesStorageContext?.controlBrowserStorageSet(
            params: params,
            key: key,
            value: value
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .unavailable(let storageType):
            return .err(
                code: "invalid_state",
                message: "Storage unavailable",
                data: .object(["type": .string(storageType)])
            )
        case .resolved(let workspaceID, let surfaceID, let storageType, let resolvedKey):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "type": .string(storageType),
                    "key": .string(resolvedKey),
                ]
            ))
        }
    }

    // MARK: - storage.clear

    func browserStorageClear(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = cookiesStorageContext?.controlBrowserStorageClear(
            params: params
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .unavailable(let storageType):
            return .err(
                code: "invalid_state",
                message: "Storage unavailable",
                data: .object(["type": .string(storageType)])
            )
        case .resolved(let workspaceID, let surfaceID, let storageType):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "type": .string(storageType),
                    "cleared": .bool(true),
                ]
            ))
        }
    }
}

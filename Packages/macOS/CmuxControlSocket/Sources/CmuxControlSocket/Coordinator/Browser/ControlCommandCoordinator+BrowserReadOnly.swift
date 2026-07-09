internal import Foundation

/// The non-JS-evaluating, main-actor read-only browser getters
/// (`browser.get.title`, `browser.frame.select`, `browser.frame.main`,
/// `browser.screenshot`), lifted byte-faithfully from the former
/// `TerminalController.v2BrowserGetTitle` / `v2BrowserFrameSelect` /
/// `v2BrowserFrameMain` / `v2BrowserScreenshot` bodies.
///
/// The coordinator owns the param parsing/validation and builds each payload
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries the `v2BrowserWithPanel` bodies returned). The app-coupled work
/// (panel resolution, `pageTitle` read, the iframe probe + per-surface frame
/// selector cache, and the viewport-snapshot capture + temp-file write) runs
/// behind the ``ControlBrowserContext`` seam and returns a typed Sendable
/// resolution.
///
/// These commands run on the main actor: the title/frame reads do not block on
/// page JS the way `browser.navigate`/`browser.eval` do (the frame probe is a
/// short synchronous same-origin check), and the screenshot capture awaits a
/// snapshot callback rather than blocking page JS, so the `@MainActor`
/// coordinator can host them. The shared panel-resolution-failure mapping and
/// identity-payload shaping are reused from
/// `ControlCommandCoordinator+BrowserCookiesStorage.swift`.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the read-only browser-getter
    /// domain this coordinator owns, returning the typed result; returns `nil`
    /// otherwise so the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned here.
    func handleBrowserReadOnly(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.get.title":
            return browserGetTitle(request.params)
        case "browser.frame.select":
            return browserFrameSelect(request.params)
        case "browser.frame.main":
            return browserFrameMain(request.params)
        case "browser.screenshot":
            return browserScreenshot(request.params)
        default:
            return nil
        }
    }

    /// The browser-domain view of the seam. `ControlCommandContext` already
    /// refines ``ControlBrowserContext``, so this is a plain widening of the
    /// stored `context` (no downcast), matching the cross-file
    /// `browserContext` / `cookiesStorageContext` accessors without their
    /// always-succeeds-cast warning.
    private var readOnlyBrowserContext: (any ControlBrowserContext)? {
        context
    }

    // MARK: - get.title

    /// `browser.get.title` — the resolved browser surface's page title.
    private func browserGetTitle(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = readOnlyBrowserContext?.controlBrowserGetTitle(params: params)
            ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .resolved(let workspaceID, let surfaceID, let title):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["title": .string(title)]
            ))
        }
    }

    // MARK: - frame.select

    /// `browser.frame.select` — pin the resolved surface to a same-origin iframe.
    private func browserFrameSelect(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: the `Missing selector` guard runs before the
        // `v2BrowserWithPanel` head.
        guard let rawSelector = browserSelector(params) else {
            return .err(code: "invalid_params", message: "Missing selector", data: nil)
        }
        let resolution = readOnlyBrowserContext?.controlBrowserFrameSelect(
            params: params,
            rawSelector: rawSelector
        ) ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .elementRefNotFound(let raw):
            return .err(
                code: "not_found",
                message: "Element reference not found",
                data: .object(["selector": .string(raw)])
            )
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .crossOrigin(let selector):
            return .err(
                code: "not_supported",
                message: "Cross-origin iframe control is not supported",
                data: .object(["selector": .string(selector)])
            )
        case .frameNotFound(let selector):
            return .err(
                code: "not_found",
                message: "Frame not found",
                data: .object(["selector": .string(selector)])
            )
        case .selected(let workspaceID, let surfaceID, let frameSelector):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["frame_selector": .string(frameSelector)]
            ))
        }
    }

    // MARK: - frame.main

    /// `browser.frame.main` — clear the resolved surface's pinned frame selector.
    private func browserFrameMain(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = readOnlyBrowserContext?.controlBrowserFrameMain(params: params)
            ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .resolved(let workspaceID, let surfaceID):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["frame_selector": .null]
            ))
        }
    }

    // MARK: - screenshot

    /// `browser.screenshot` — capture the resolved browser's automation-visible
    /// viewport as PNG.
    private func browserScreenshot(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = readOnlyBrowserContext?.controlBrowserScreenshot(params: params)
            ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .timedOut:
            return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
        case .captureFailed:
            return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
        case .resolved(let workspaceID, let surfaceID, let pngBase64, let filePath, let fileURL):
            var extra: [String: JSONValue] = ["png_base64": .string(pngBase64)]
            if let filePath { extra["path"] = .string(filePath) }
            if let fileURL { extra["url"] = .string(fileURL) }
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: extra
            ))
        }
    }

    /// The browser selector param (`selector`/`sel`/`element_ref`/`ref`
    /// precedence), the typed twin of `TerminalController.v2BrowserSelector`.
    private func browserSelector(_ params: [String: JSONValue]) -> String? {
        string(params, "selector")
            ?? string(params, "sel")
            ?? string(params, "element_ref")
            ?? string(params, "ref")
    }
}

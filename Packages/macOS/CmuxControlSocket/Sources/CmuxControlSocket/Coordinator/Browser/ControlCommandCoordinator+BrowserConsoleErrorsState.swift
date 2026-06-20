internal import Foundation

/// The non-JS-eval-worker-lane, main-actor browser telemetry + session-state
/// commands (`browser.console.list`, `browser.console.clear`,
/// `browser.errors.list`, `browser.state.save`, `browser.state.load`), lifted
/// byte-faithfully from the former `TerminalController.v2BrowserConsoleList` /
/// `v2BrowserConsoleClear` / `v2BrowserErrorsList` / `v2BrowserStateSave` /
/// `v2BrowserStateLoad` bodies.
///
/// The coordinator owns the param parsing/validation (the `Missing path` guard,
/// the `clear` flag, the `console.clear` → `console.list`-with-`clear` mapping)
/// and builds each payload directly as a ``JSONValue`` (the typed twin of the
/// legacy `[String: Any]` dictionaries the `v2BrowserWithPanel` bodies returned).
/// The app-coupled work (panel resolution through the shared
/// `v2BrowserWithPanel` head, the telemetry-hook bootstrap, the console/error
/// ring read/clear JS, the cookie/storage read+write, the per-surface frame
/// selector cache, and the JSON state-file I/O) runs behind the
/// ``ControlBrowserContext`` seam and returns a typed Sendable resolution.
///
/// These commands run on the main actor: like cookies/storage/get.title they are
/// NOT on the socket-worker lane (the JS-eval read/clear hops are short
/// synchronous reads, not the blocking page-JS waits of
/// `browser.navigate`/`browser.eval`), so the `@MainActor` coordinator can host
/// them. The shared panel-resolution-failure mapping and identity-payload
/// shaping are reused from `ControlCommandCoordinator+BrowserCookiesStorage.swift`.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the browser console/errors/state
    /// domain this coordinator owns, returning the typed result; returns `nil`
    /// otherwise so the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned here.
    func handleBrowserConsoleErrorsState(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "browser.console.list":
            return browserConsoleList(request.params, clear: bool(request.params, "clear") ?? false)
        case "browser.console.clear":
            // Legacy: `v2BrowserConsoleClear` injects `clear=true` and forwards to
            // `v2BrowserConsoleList`.
            return browserConsoleList(request.params, clear: true)
        case "browser.errors.list":
            return browserErrorsList(request.params, clear: bool(request.params, "clear") ?? false)
        case "browser.state.save":
            return browserStateSave(request.params)
        case "browser.state.load":
            return browserStateLoad(request.params)
        default:
            return nil
        }
    }

    /// The browser-domain view of the seam. `ControlCommandContext` already
    /// refines ``ControlBrowserContext``, so this is a plain widening of the
    /// stored `context` (no downcast).
    private var consoleErrorsStateContext: (any ControlBrowserContext)? {
        context
    }

    // MARK: - console.list / console.clear

    /// `browser.console.list` / `browser.console.clear` — read (and optionally
    /// clear) the captured console-log ring.
    private func browserConsoleList(
        _ params: [String: JSONValue],
        clear: Bool
    ) -> ControlCallResult {
        let resolution = consoleErrorsStateContext?.controlBrowserConsoleList(
            params: params,
            clear: clear
        ) ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .resolved(let workspaceID, let surfaceID, let entries):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "entries": .array(entries),
                    "count": .int(Int64(entries.count)),
                ]
            ))
        }
    }

    // MARK: - errors.list

    /// `browser.errors.list` — read (and optionally clear) the captured
    /// uncaught-error ring.
    private func browserErrorsList(
        _ params: [String: JSONValue],
        clear: Bool
    ) -> ControlCallResult {
        let resolution = consoleErrorsStateContext?.controlBrowserErrorsList(
            params: params,
            clear: clear
        ) ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .resolved(let workspaceID, let surfaceID, let errors):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "errors": .array(errors),
                    "count": .int(Int64(errors.count)),
                ]
            ))
        }
    }

    // MARK: - state.save

    /// `browser.state.save` — snapshot URL/cookies/storage/frame-selector to JSON.
    private func browserStateSave(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: the `Missing path` guard runs before the `v2BrowserWithPanel`
        // head.
        guard let path = string(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        let resolution = consoleErrorsStateContext?.controlBrowserStateSave(
            params: params,
            path: path
        ) ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .writeFailed(let filePath, let error):
            return .err(
                code: "internal_error",
                message: "Failed to write state file",
                data: .object(["path": .string(filePath), "error": .string(error)])
            )
        case .resolved(let workspaceID, let surfaceID, let savedPath, let cookieCount):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "path": .string(savedPath),
                    "cookies": .int(Int64(cookieCount)),
                ]
            ))
        }
    }

    // MARK: - state.load

    /// `browser.state.load` — restore frame-selector/navigation/cookies/storage.
    private func browserStateLoad(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: the `Missing path` guard runs first, then the file read/parse,
        // then the `v2BrowserWithPanel` head.
        guard let path = string(params, "path") else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        let resolution = consoleErrorsStateContext?.controlBrowserStateLoad(
            params: params,
            path: path
        ) ?? .failed(.tabManagerUnavailable)
        switch resolution {
        case .notObject(let filePath):
            return .err(
                code: "invalid_params",
                message: "State file must contain a JSON object",
                data: .object(["path": .string(filePath)])
            )
        case .readFailed(let filePath, let error):
            return .err(
                code: "not_found",
                message: "Failed to read state file",
                data: .object(["path": .string(filePath), "error": .string(error)])
            )
        case .failed(let failure):
            return browserPanelResolutionError(failure)
        case .resolved(let workspaceID, let surfaceID, let loadedPath):
            return .ok(browserPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: [
                    "path": .string(loadedPath),
                    "loaded": .bool(true),
                ]
            ))
        }
    }
}

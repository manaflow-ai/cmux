internal import Foundation

/// The non-JS-evaluating, main-actor `browser.addinitscript` /
/// `browser.addscript` / `browser.addstyle` / `browser.dialog.accept` /
/// `browser.dialog.dismiss` / `browser.import.dialog` commands, lifted
/// byte-faithfully from the former `TerminalController.v2BrowserAddInitScript` /
/// `v2BrowserAddScript` / `v2BrowserAddStyle` / `v2BrowserDialogRespond` /
/// `v2BrowserImportDialog` bodies.
///
/// The coordinator owns the param parsing/validation and builds each payload
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries the `v2BrowserWithPanel` bodies returned). The app-coupled work
/// (panel resolution via the shared `v2BrowserWithPanel` head, the per-surface
/// init-script / init-style / dialog-queue caches, `WKUserScript` registration,
/// the script/dialog page JS eval, and the `BrowserProfileStore` /
/// `BrowserDataImportCoordinator` reach) runs behind the ``ControlBrowserContext``
/// seam and returns a typed Sendable resolution.
///
/// These run on the main actor (the addscript/dialog page JS is a short
/// synchronous eval hop, not the blocking page-load wait that
/// `browser.navigate`/`browser.eval` perform), so the `@MainActor` coordinator
/// can host them. The JS-evaluating worker-lane methods stay app-side.
extension ControlCommandCoordinator {
    /// Maps a shared panel-resolution failure to the exact legacy `.err` the
    /// `v2BrowserWithPanel` head produced (the cross-file twin of the
    /// cookies/storage `browserPanelResolutionError`).
    private func scriptDialogPanelError(
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
    /// command's extra keys (the cross-file twin of the cookies/storage
    /// `browserPanelPayload`).
    private func scriptDialogPanelPayload(
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

    // MARK: - addinitscript

    /// `browser.addinitscript` — register a document-start init script.
    func browserAddInitScript(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: `Missing script` is checked before the panel resolution.
        guard let script = string(params, "script") ?? string(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        let resolution = context?.controlBrowserAddInitScript(
            params: params,
            script: script
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return scriptDialogPanelError(failure)
        case .resolved(let workspaceID, let surfaceID, let scriptCount):
            return .ok(scriptDialogPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["scripts": .int(Int64(scriptCount))]
            ))
        }
    }

    // MARK: - addscript

    /// `browser.addscript` — evaluate a one-shot script.
    func browserAddScript(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: `Missing script` is checked before the panel resolution.
        guard let script = string(params, "script") ?? string(params, "content") else {
            return .err(code: "invalid_params", message: "Missing script", data: nil)
        }
        let resolution = context?.controlBrowserAddScript(
            params: params,
            script: script
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return scriptDialogPanelError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .resolved(let workspaceID, let surfaceID, let value):
            return .ok(scriptDialogPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["value": value]
            ))
        }
    }

    // MARK: - addstyle

    /// `browser.addstyle` — register a document-start `<style>`-injecting script.
    func browserAddStyle(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy: `Missing css/style content` is checked before the panel
        // resolution.
        guard let css = string(params, "css") ?? string(params, "style") ?? string(params, "content") else {
            return .err(code: "invalid_params", message: "Missing css/style content", data: nil)
        }
        let resolution = context?.controlBrowserAddStyle(
            params: params,
            css: css
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return scriptDialogPanelError(failure)
        case .resolved(let workspaceID, let surfaceID, let styleCount):
            return .ok(scriptDialogPanelPayload(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                extra: ["styles": .int(Int64(styleCount))]
            ))
        }
    }

    // MARK: - dialog.accept / dialog.dismiss

    /// `browser.dialog.accept` / `browser.dialog.dismiss` — respond to the front
    /// pending in-page dialog. `accept` is the accept/dismiss intent.
    func browserDialogRespond(_ params: [String: JSONValue], accept: Bool) -> ControlCallResult {
        // Legacy: `text` falls back from `text` to `prompt_text`.
        let text = string(params, "text") ?? string(params, "prompt_text")
        let resolution = context?.controlBrowserDialogRespond(
            params: params,
            accept: accept,
            text: text
        ) ?? .failed(.tabManagerUnavailable)

        switch resolution {
        case .failed(let failure):
            return scriptDialogPanelError(failure)
        case .jsError(let message):
            return .err(code: "js_error", message: message, data: nil)
        case .notFound(let pending):
            return .err(
                code: "not_found",
                message: "No pending dialog",
                data: .object(["pending": .array(pending)])
            )
        case .resolved(let workspaceID, let surfaceID, let dialog, let remaining):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "accepted": .bool(accept),
                "dialog": dialog,
                "remaining": remaining,
            ]))
        }
    }

    // MARK: - import.dialog

    /// `browser.import.dialog` — schedule the browser data-import dialog.
    func browserImportDialog(_ params: [String: JSONValue]) -> ControlCallResult {
        let resolution = context?.controlBrowserImportDialog(params: params)
            ?? .opened(scopeRawValue: nil)

        switch resolution {
        case .scopeEmpty:
            return .err(
                code: "invalid_params",
                message: "scope must be a non-empty string",
                data: .object(["param": .string("scope")])
            )
        case .scopeInvalid:
            return .err(
                code: "invalid_params",
                message: "scope is invalid",
                data: .object(["param": .string("scope")])
            )
        case .destinationProfileEmpty:
            return .err(
                code: "invalid_params",
                message: "destination_profile must be a non-empty string",
                data: .object(["param": .string("destination_profile")])
            )
        case .destinationProfileNoMatch:
            return .err(
                code: "invalid_params",
                message: "destination_profile does not match a cmux browser profile",
                data: .object(["param": .string("destination_profile")])
            )
        case .destinationProfileCreateFailed:
            return .err(
                code: "invalid_params",
                message: "destination_profile could not be created",
                data: .object(["param": .string("destination_profile")])
            )
        case .opened(let scopeRawValue):
            return .ok(.object([
                "opened": .bool(true),
                "scope": scopeRawValue.map { JSONValue.string($0) } ?? .null,
            ]))
        }
    }
}

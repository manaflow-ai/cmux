import CmuxDockExtensions
import Foundation

/// v2 socket verbs for Dock TUI extensions (`extension.list/preview/install/
/// discard/uninstall/link/unlink/open/paths`).
///
/// Threading (socket policy): every mutating/listing verb runs on the
/// socket-worker lane via `v2AsyncResultCall` because the bodies await the
/// `@MainActor` extensions store (which itself suspends into service actors
/// for git/network/build work) — the awaits hop to the main actor without
/// blocking it, and the worker lane keeps the socket pipeline free during
/// long previews/installs. `extension.open` and `extension.paths` are quick,
/// synchronous main-actor cases: `open` intentionally mutates focus (it is in
/// `focusIntentV2Methods` — an explicit user command to show a pane) and
/// `paths` only reads main-actor state.
///
/// Consent parity: `extension.preview` stages a checkout and returns a
/// one-shot `preview_token`; nothing runs until `extension.install` confirms
/// that token (the CLI's y/N stands in for the GUI consent sheet).
extension TerminalController {
    func v2ExtensionList(params: [String: Any]) async -> V2CallResult {
        let runtime = DockExtensionsRuntime.shared
        await runtime.store.reload()
        return .ok(["extensions": runtime.store.installed.map(\.socketPayload)])
    }

    func v2ExtensionPreview(params: [String: Any]) async -> V2CallResult {
        let source = v2OptionalTrimmedRawString(params, "source")
        let updateId = v2OptionalTrimmedRawString(params, "id")
        let ref = v2OptionalTrimmedRawString(params, "ref")
        guard source != nil || updateId != nil else {
            return .err(code: "invalid_params", message: "source or id is required", data: nil)
        }
        do {
            let (token, preview) = try await DockExtensionsRuntime.shared.socketPreview(
                sourceInput: source,
                updateId: updateId,
                ref: ref
            )
            return .ok(preview.socketPayload(token: token))
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    func v2ExtensionInstall(params: [String: Any]) async -> V2CallResult {
        guard let token = v2OptionalTrimmedRawString(params, "preview_token") else {
            return .err(code: "invalid_params", message: "preview_token is required", data: nil)
        }
        do {
            guard let preview = try await DockExtensionsRuntime.shared.socketInstall(token: token) else {
                return .err(
                    code: "not_found",
                    message: "unknown or expired preview_token; run extension.preview again",
                    data: nil
                )
            }
            var payload: [String: Any] = [
                "id": preview.manifest.id,
                "name": preview.manifest.name,
            ]
            if let sha = preview.resolvedSha { payload["pinned_sha"] = sha }
            return .ok(payload)
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    func v2ExtensionDiscard(params: [String: Any]) async -> V2CallResult {
        guard let token = v2OptionalTrimmedRawString(params, "preview_token") else {
            return .err(code: "invalid_params", message: "preview_token is required", data: nil)
        }
        let discarded = await DockExtensionsRuntime.shared.socketDiscard(token: token)
        return .ok(["discarded": discarded])
    }

    func v2ExtensionUninstall(params: [String: Any]) async -> V2CallResult {
        guard let id = v2OptionalTrimmedRawString(params, "id") else {
            return .err(code: "invalid_params", message: "id is required", data: nil)
        }
        do {
            try await DockExtensionsRuntime.shared.store.uninstall(id: id)
            return .ok(["id": id])
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    func v2ExtensionLink(params: [String: Any]) async -> V2CallResult {
        guard let path = v2OptionalTrimmedRawString(params, "path"), path.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "path is required and must be absolute", data: nil)
        }
        do {
            try await DockExtensionsRuntime.shared.store.link(directoryPath: path)
            await DockExtensionsRuntime.shared.store.reload()
            let linked = await DockExtensionsRuntime.shared.store.installed.first {
                $0.rootDirectory.path == URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            }
            var payload: [String: Any] = ["path": path]
            if let linked { payload["id"] = linked.id }
            return .ok(payload)
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    func v2ExtensionUnlink(params: [String: Any]) async -> V2CallResult {
        guard let id = v2OptionalTrimmedRawString(params, "id") else {
            return .err(code: "invalid_params", message: "id is required", data: nil)
        }
        do {
            try await DockExtensionsRuntime.shared.store.unlink(id: id)
            return .ok(["id": id])
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    /// Main-actor, focus-intent (`focusIntentV2Methods`): the user explicitly
    /// asked to open a pane, so revealing the Dock and focusing it is the
    /// command's purpose.
    func v2ExtensionOpen(params: [String: Any]) -> V2CallResult {
        let runtime = DockExtensionsRuntime.shared
        do {
            if let qualifiedId = v2OptionalTrimmedRawString(params, "qualified_id") {
                try runtime.store.openPane(qualifiedId: qualifiedId)
                return .ok(["qualified_id": qualifiedId])
            }
            guard let id = v2OptionalTrimmedRawString(params, "id") else {
                return .err(code: "invalid_params", message: "qualified_id or id is required", data: nil)
            }
            guard let installed = runtime.store.installedExtension(id: id) else {
                return Self.v2ExtensionError(DockExtensionError.notInstalled(id: id))
            }
            let panes = installed.launchablePanes
            guard panes.count == 1, let pane = panes.first else {
                return .err(
                    code: "invalid_params",
                    message: "extension \"\(id)\" has \(panes.count) launchable panes; pass qualified_id (<id>.<pane>)",
                    data: nil
                )
            }
            let qualifiedId = DockExtensionPane.qualifiedId(extensionId: id, paneId: pane.id)
            try runtime.store.openPane(qualifiedId: qualifiedId)
            return .ok(["qualified_id": qualifiedId])
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    /// Main-actor: reads @MainActor extension state only (reason comment per
    /// socket policy); no UI mutation, no focus.
    func v2ExtensionPaths(params: [String: Any]) -> V2CallResult {
        guard let id = v2OptionalTrimmedRawString(params, "id") else {
            return .err(code: "invalid_params", message: "id is required", data: nil)
        }
        guard let payload = DockExtensionsRuntime.shared.socketPaths(id: id) else {
            return Self.v2ExtensionError(DockExtensionError.notInstalled(id: id))
        }
        return .ok(payload)
    }

    private static func v2ExtensionError(_ error: Error) -> V2CallResult {
        let message = (error as? DockExtensionError)?.errorDescription ?? error.localizedDescription
        let code: String
        switch error as? DockExtensionError {
        case .invalidSource, .manifestInvalid, .manifestTooLarge, .unsupportedManifestVersion:
            code = "invalid_params"
        case .notInstalled, .paneNotFound, .manifestNotFound, .linkedDirectoryMissing:
            code = "not_found"
        case .needsReconsent, .extensionDisabled, .duplicateId, .minCmuxVersionNotSatisfied,
             .platformNotSupported:
            code = "failed_precondition"
        case .gitUnavailable, .hostUnavailable:
            code = "unavailable"
        case .gitFailed, .buildFailed, .buildTimedOut, .stagingFailed, .none:
            code = "request_error"
        }
        return .err(code: code, message: message, data: nil)
    }
}

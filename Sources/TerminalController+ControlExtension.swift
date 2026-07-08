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
    /// The worker-lane extension verbs; `socketWorkerV2Response` routes them
    /// all through `v2ExtensionWorkerResponse` in one case.
    nonisolated static let extensionWorkerV2Methods: [String] = [
        "extension.list", "extension.preview", "extension.install", "extension.discard",
        "extension.uninstall", "extension.link", "extension.unlink",
    ]

    /// Every extension verb, advertised by `system.capabilities`.
    nonisolated static let extensionV2Methods: [String] =
        extensionWorkerV2Methods + ["extension.open", "extension.paths"]

    /// Dispatches one worker-lane extension verb (see the file header for the
    /// threading rationale). Timeouts: `extension.preview` covers the composed
    /// git budget — 60s resolve + 600s fetch + manifest parse headroom (the
    /// CLI client waits 760s) — and `extension.install` adds build-step budget
    /// on top of that.
    nonisolated func v2ExtensionWorkerResponse(id: Any?, method: String, params: [String: Any]) -> String {
        switch method {
        case "extension.list":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) { await self.v2ExtensionList(params: params) }
        case "extension.preview":
            return v2AsyncResultCall(id: id, timeoutSeconds: 720) { await self.v2ExtensionPreview(params: params) }
        case "extension.install":
            return v2AsyncResultCall(id: id, timeoutSeconds: 900) { await self.v2ExtensionInstall(params: params) }
        case "extension.discard":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) { await self.v2ExtensionDiscard(params: params) }
        case "extension.uninstall":
            return v2AsyncResultCall(id: id, timeoutSeconds: 60) { await self.v2ExtensionUninstall(params: params) }
        case "extension.link":
            return v2AsyncResultCall(id: id, timeoutSeconds: 60) { await self.v2ExtensionLink(params: params) }
        case "extension.unlink":
            return v2AsyncResultCall(id: id, timeoutSeconds: 60) { await self.v2ExtensionUnlink(params: params) }
        default:
            return v2Error(id: id, code: "invalid_dispatch", message: "\(method) is not a worker-lane extension verb")
        }
    }

    /// Dispatches the two quick main-actor verbs (`extension.open`, a
    /// focus-intent command, and `extension.paths`, a main-actor state read)
    /// for `v2LegacyMainActorResponse`.
    func v2ExtensionMainActorResponse(id: Any?, method: String, params: [String: Any]) -> String {
        method == "extension.open"
            ? v2Result(id: id, v2ExtensionOpen(params: params))
            : v2Result(id: id, v2ExtensionPaths(params: params))
    }

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
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.sourceOrIdRequired", defaultValue: "source or id is required"), data: nil)
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
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.previewTokenRequired", defaultValue: "preview_token is required"), data: nil)
        }
        do {
            guard let preview = try await DockExtensionsRuntime.shared.socketInstall(token: token) else {
                return .err(
                    code: "not_found",
                    message: String(localized: "controlExtension.error.previewTokenUnknown", defaultValue: "unknown or expired preview_token; run extension.preview again"),
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
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.previewTokenRequired", defaultValue: "preview_token is required"), data: nil)
        }
        let discarded = DockExtensionsRuntime.shared.socketDiscard(token: token)
        return .ok(["discarded": discarded])
    }

    func v2ExtensionUninstall(params: [String: Any]) async -> V2CallResult {
        guard let id = v2OptionalTrimmedRawString(params, "id") else {
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.idRequired", defaultValue: "id is required"), data: nil)
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
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.pathRequired", defaultValue: "path is required and must be absolute"), data: nil)
        }
        do {
            try await DockExtensionsRuntime.shared.store.link(directoryPath: path)
            await DockExtensionsRuntime.shared.store.reload()
            let linked = DockExtensionsRuntime.shared.store.installed.first {
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
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.idRequired", defaultValue: "id is required"), data: nil)
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
            // `target` resolves ambiguity server-side: extension ids may
            // contain dots while pane ids may not, so a dotted target is
            // FIRST matched as an exact extension id and only then split as
            // `<id>.<pane>` — `cmux extension open com.example.tool` works.
            if let target = v2OptionalTrimmedRawString(params, "target") {
                if runtime.store.installedExtension(id: target) != nil {
                    return openSolePane(ofExtension: target, runtime: runtime)
                }
                if DockExtensionPane.splitQualifiedId(target) != nil {
                    try runtime.store.openPane(qualifiedId: target)
                    return .ok(["qualified_id": target])
                }
                return Self.v2ExtensionError(DockExtensionError.notInstalled(id: target))
            }
            if let qualifiedId = v2OptionalTrimmedRawString(params, "qualified_id") {
                try runtime.store.openPane(qualifiedId: qualifiedId)
                return .ok(["qualified_id": qualifiedId])
            }
            guard let id = v2OptionalTrimmedRawString(params, "id") else {
                return .err(code: "invalid_params", message: String(localized: "controlExtension.error.targetRequired", defaultValue: "target, qualified_id, or id is required"), data: nil)
            }
            guard runtime.store.installedExtension(id: id) != nil else {
                return Self.v2ExtensionError(DockExtensionError.notInstalled(id: id))
            }
            return openSolePane(ofExtension: id, runtime: runtime)
        } catch {
            return Self.v2ExtensionError(error)
        }
    }

    private func openSolePane(ofExtension id: String, runtime: DockExtensionsRuntime) -> V2CallResult {
        guard let installed = runtime.store.installedExtension(id: id) else {
            return Self.v2ExtensionError(DockExtensionError.notInstalled(id: id))
        }
        let panes = installed.launchablePanes
        guard panes.count == 1, let pane = panes.first else {
            return .err(
                code: "invalid_params",
                message: String(localized: "controlExtension.error.multiplePanes", defaultValue: "extension \"\(id)\" has \(panes.count) launchable panes; pass <id>.<pane>"),
                data: nil
            )
        }
        let qualifiedId = DockExtensionPane.qualifiedId(extensionId: id, paneId: pane.id)
        do {
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
            return .err(code: "invalid_params", message: String(localized: "controlExtension.error.idRequired", defaultValue: "id is required"), data: nil)
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
             .platformNotSupported, .operationInProgress, .tooManyPendingPreviews:
            code = "failed_precondition"
        case .gitUnavailable, .hostUnavailable:
            code = "unavailable"
        case .gitFailed, .buildFailed, .buildTimedOut, .stagingFailed, .none:
            code = "request_error"
        }
        return .err(code: code, message: message, data: nil)
    }
}

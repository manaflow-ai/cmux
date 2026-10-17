import AppKit
import CmuxBrowser
import CmuxControlSocket
import Foundation

/// `browser.extension.*`: Chrome extension management for Chromium panels.
///
/// The surface picks the browser profile (extensions are per profile) and the
/// tab for tab-scoped calls. What an automation caller may do is decided by
/// ``BrowserExtensionAutomationPolicy``: anything that widens an extension's
/// reach waits for the person to accept a cmux sheet in the panel's window.
/// None of these methods is allowlisted for the `cmux ssh` relay.
extension TerminalController {
    /// The socket methods and the operation each one performs.
    nonisolated static let v2BrowserExtensionMethods: [String: BrowserExtensionOperation] = [
        "browser.extension.list": .list,
        "browser.extension.load": .loadUnpacked,
        "browser.extension.install_crx": .installPacked,
        "browser.extension.enable": .enable,
        "browser.extension.disable": .disable,
        "browser.extension.remove": .remove,
        "browser.extension.reload": .reload,
        "browser.extension.pin": .pin,
        "browser.extension.unpin": .unpin,
        "browser.extension.move": .move,
        "browser.extension.options": .options,
        "browser.extension.run": .run,
        "browser.extension.command": .command,
        // open_page with page=manage is .openManagement (see v2BrowserExtensionOperation).
        "browser.extension.open_page": .openWebStore,
    ]

    /// How long a consent sheet may wait for the person before the request times out.
    nonisolated static let v2BrowserExtensionConsentTimeout = BrowserExtensionControlRequest.consentSeconds

    /// Runs one `browser.extension.*` method; waits on the socket worker.
    nonisolated func v2BrowserExtensionOnSocketWorker(id: Any?, method: String, params: [String: Any]) -> String {
        guard let mapped = Self.v2BrowserExtensionMethods[method] else {
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
        let isWebStore = (params["page"] as? String) == BrowserExtensionPage.webStore.rawValue
        let operation: BrowserExtensionOperation = mapped == .openWebStore && !isWebStore ? .openManagement : mapped
        // Reload may need consent (a disabled extension), so it gets the consent window too.
        let mayAsk = BrowserExtensionAutomationPolicy().decision(for: operation) != .allow || operation == .reload
        let timeout = mayAsk ? Self.v2BrowserExtensionConsentTimeout : BrowserExtensionControlRequest.quickSeconds - 5
        return v2AsyncResultCall(id: id, timeoutSeconds: timeout) {
            await self.v2BrowserExtension(operation, params: params)
        }
    }

    private func v2BrowserExtensionError(_ code: String, _ message: String, _ data: Any? = nil) -> V2CallResult {
        .err(code: code, message: message, data: data)
    }

    private func v2BrowserExtension(_ operation: BrowserExtensionOperation, params: [String: Any]) async -> V2CallResult {
        let policy = BrowserExtensionAutomationPolicy()
        if policy.decision(for: operation) == .deny {
            return v2BrowserExtensionError("forbidden", String(
                localized: "cli.browser.extension.error.crxRefused",
                defaultValue: "Packed .crx files are not installed. Load the unpacked folder or install from the Chrome Web Store."
            ))
        }
        v2RefreshKnownRefs()
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return v2BrowserExtensionError("unavailable", String(
                localized: "cli.browser.error.tabManagerUnavailable", defaultValue: "Browser controls are unavailable"))
        }
        let resolved = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager)
        if let error = resolved.error { return error }
        guard let ctx = resolved.context else {
            return v2BrowserExtensionError("internal_error", String(
                localized: "cli.browser.error.operationFailed", defaultValue: "Browser operation failed"))
        }
        guard let host = ctx.browserPanel.extensionHost else {
            return v2BrowserExtensionError("unsupported", String(
                localized: "cli.browser.extension.error.needsChromium",
                defaultValue: "Extensions need a Chromium browser. Open one with: cmux browser open --engine chromium <url>"
            ), ["engine": "webkit"])
        }
        let store = host.extensionStore
        store.refresh()

        if operation == .list {
            return .ok(v2BrowserPanelFields(ctx, adding: [
                "managed": store.supportsManagement,
                "extensions": store.extensions.map(v2BrowserExtensionPayload),
                "commands": store.commands.map(v2BrowserExtensionCommandPayload),
                "actions": host.extensionActions.map(\.id),
                // The extension whose action popup is open on this page, so a
                // caller can tell whether `run` opened one.
                "open_popup": v2OrNull(host.openExtensionPopup),
            ]))
        }
        if operation == .openWebStore || operation == .openManagement {
            let raw = (params["page"] as? String) ?? BrowserExtensionPage.management.rawValue
            guard let page = BrowserExtensionPage(rawValue: raw) else {
                return v2BrowserExtensionError("invalid_params", String(
                    localized: "cli.browser.extension.error.page", defaultValue: "page must be webstore or manage"))
            }
            if policy.decision(for: operation) == .requiresConsent {
                let content = BrowserExtensionPromptContent(automation: operation, name: page.url.absoluteString)
                guard await v2BrowserExtensionConsent(content, ctx: ctx, host: host) else {
                    return v2BrowserExtensionDeclined()
                }
            }
            ctx.browserPanel.openExtensionPage(page, focus: false)
            return .ok(v2BrowserPanelFields(ctx, adding: ["url": page.url.absoluteString]))
        }
        guard store.supportsManagement else {
            return v2BrowserExtensionError("unsupported", String(
                localized: "cli.browser.extension.error.needsFork",
                defaultValue: "This Chromium build cannot manage extensions."))
        }

        if operation == .loadUnpacked {
            return await v2BrowserExtensionLoad(params: params, ctx: ctx, store: store)
        }

        let text = (params["extension"] as? String) ?? ""
        guard let info = store.extensionInfo(matching: text) else {
            return v2BrowserExtensionError("not_found", String(
                localized: "cli.browser.extension.error.unknown", defaultValue: "No installed extension matches \u{201C}\(text)\u{201D}."))
        }
        if policy.decision(for: operation, target: info) == .requiresConsent {
            let summary = info.path.isEmpty ? nil : BrowserExtensionManifestSummary.read(folder: info.path)
            let content = BrowserExtensionPromptContent(
                automation: operation, name: info.name, permissions: summary?.permissions ?? []
            )
            guard await v2BrowserExtensionConsent(content, ctx: ctx, host: host, icon: info.iconPath) else {
                return v2BrowserExtensionDeclined()
            }
        }

        let accepted: Bool
        switch operation {
        case .enable: accepted = info.canToggle && store.setEnabled(info.id, true)
        case .disable: accepted = info.canToggle && store.setEnabled(info.id, false)
        case .remove: accepted = info.canRemove && store.uninstall(info.id)
        case .reload: accepted = store.reload(info.id)
        case .pin: accepted = info.hasAction && store.setPinned(info.id, true)
        case .unpin: accepted = store.setPinned(info.id, false)
        case .move:
            let index = (params["index"] as? Int) ?? (params["index"] as? String).flatMap(Int.init) ?? -1
            accepted = index >= 0 && store.movePinned(info.id, to: index)
        case .options: accepted = store.openOptions(info.id, from: host.extensionTab)
        case .run:
            guard host.extensionActions.contains(where: { $0.id == info.id }) else {
                return v2BrowserExtensionError("not_found", String(
                    localized: "cli.browser.extension.error.noAction", defaultValue: "This extension has no toolbar action on this page."))
            }
            host.extensionTab.requestExtensionAction(info.id)
            accepted = true
        case .command:
            let name = (params["command"] as? String) ?? ""
            let command = store.commands.first { $0.extensionID == info.id && $0.name == name }
                ?? BrowserExtensionCommand(extensionID: info.id, name: name, keyCode: 0, modifiers: 0)
            accepted = !name.isEmpty && store.run(command, in: host.extensionTab)
        case .list, .openWebStore, .openManagement, .loadUnpacked, .installPacked:
            accepted = false
        }
        guard accepted else {
            return v2BrowserExtensionError("refused", String(
                localized: "cli.browser.extension.error.refused", defaultValue: "Chromium refused the change."))
        }
        let current = store.extensionInfo(matching: info.id)
        return .ok(v2BrowserPanelFields(ctx, adding: [
            "extension_id": info.id,
            "extension": current.map(v2BrowserExtensionPayload) ?? NSNull(),
        ]))
    }

    private func v2BrowserExtensionLoad(
        params: [String: Any], ctx: V2BrowserPanelContext, store: BrowserExtensionStore
    ) async -> V2CallResult {
        let raw = (params["path"] as? String) ?? ""
        // Resolve symlinks so the sheet names the folder Chromium will load.
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard !raw.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("manifest.json")) else {
            return v2BrowserExtensionError("invalid_params", String(
                localized: "cli.browser.extension.error.noManifest",
                defaultValue: "No manifest.json in \u{201C}\(raw)\u{201D}. Pass an unpacked extension folder."))
        }
        guard let host = ctx.browserPanel.extensionHost else { return v2BrowserExtensionDeclined() }
        let manifestPath = (path as NSString).appendingPathComponent("manifest.json")
        let agreedManifest = FileManager.default.contents(atPath: manifestPath)
        let summary = BrowserExtensionManifestSummary.read(folder: path)
        let content = BrowserExtensionPromptContent(
            automation: .loadUnpacked, name: path, permissions: summary?.permissions ?? []
        )
        guard await v2BrowserExtensionConsent(content, ctx: ctx, host: host) else { return v2BrowserExtensionDeclined() }
        // The person agreed to the manifest shown in the sheet; refuse one that changed while it was open.
        guard let agreedManifest, FileManager.default.contents(atPath: manifestPath) == agreedManifest else {
            return v2BrowserExtensionError("conflict", String(
                localized: "cli.browser.extension.error.manifestChanged",
                defaultValue: "The extension's manifest.json changed while waiting for approval. Nothing was loaded; run the command again."))
        }
        let before = Set(store.extensions.map(\.id))
        guard store.loadUnpacked(at: path) else {
            return v2BrowserExtensionError("refused", String(
                localized: "cli.browser.extension.error.refused", defaultValue: "Chromium refused the change."))
        }
        let loaded = store.extensions.first { !before.contains($0.id) }
            ?? store.extensions.first { $0.path == path }
        return .ok(v2BrowserPanelFields(ctx, adding: [
            "path": path,
            "extension": loaded.map(v2BrowserExtensionPayload) ?? NSNull(),
        ]))
    }

    /// Shows the consent sheet in the panel's window. False when declined,
    /// timed out, or there is no window to ask in (fail closed).
    private func v2BrowserExtensionConsent(
        _ content: BrowserExtensionPromptContent, ctx: V2BrowserPanelContext, host: any BrowserExtensionHosting,
        icon iconPath: String? = nil
    ) async -> Bool {
        let window = ctx.browserPanel.extensionPageWindow ?? ctx.webView.window
        guard let window, window.attachedSheet == nil else { return false }
        let icon = iconPath.flatMap { FileManager.default.contents(atPath: $0) }
        let accepted = await BrowserExtensionDialogPresenter().present(
            content,
            icon: icon,
            in: window,
            overChromiumPage: ctx.browserPanel.activeEngineKind == .chromium
        )
        return accepted && !Task.isCancelled
    }

    private func v2BrowserExtensionDeclined() -> V2CallResult {
        v2BrowserExtensionError("declined", String(
            localized: "cli.browser.extension.error.declined",
            defaultValue: "Not allowed. The request needs your approval in the cmux window, and it was declined or not answered."))
    }

    private func v2BrowserExtensionPayload(_ info: BrowserExtensionInfo) -> [String: Any] {
        [
            "id": info.id,
            "name": info.name,
            "version": info.version,
            "description": info.summary,
            "manifest_version": info.manifestVersion,
            "location": info.location.rawValue,
            "enabled": info.isEnabled,
            "crashed": info.isTerminated,
            "blocklisted": info.isBlocklisted,
            "has_action": info.hasAction,
            "pinned": info.isPinned,
            "can_toggle": info.canToggle,
            "can_remove": info.canRemove,
            "options_url": v2OrNull(info.optionsURL?.absoluteString),
            "path": info.path,
        ]
    }

    private func v2BrowserExtensionCommandPayload(_ command: BrowserExtensionCommand) -> [String: Any] {
        [
            "extension_id": command.extensionID,
            "name": command.name,
            "description": command.summary,
            "shortcut": command.shortcut,
            "global": command.isGlobal,
        ]
    }
}

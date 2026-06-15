import CmuxSettings
import CmuxSettingsUI
import Foundation

/// App-side handler for the `settings.control.*` socket methods that back the
/// `cmux settings` CLI.
///
/// Runs on the socket-worker lane (the engine's reads/writes are `async` actor
/// hops, which the synchronous main-actor coordinator cannot host). It reuses
/// the app's live ``SettingsRuntime`` stores — the very instances the Settings
/// UI binds to — so a CLI write lands in `UserDefaults.standard`, `cmux.json`,
/// or the secret file exactly where the GUI reads it. UserDefaults changes
/// apply live through the app's existing in-process observers; after a write to
/// `cmux.json` / shortcuts the handler also triggers the same config reload the
/// `reload_config` verb uses, so file-backed changes take effect with no
/// restart.
extension TerminalController {
    /// The pure-read `settings.control.*` methods. Every other (mutating)
    /// method triggers a live config reload after it succeeds, so adding a write
    /// here would wrongly suppress that reload — keep this list reads-only.
    ///
    /// `nonisolated` so the worker-lane (`nonisolated`) handler can read it
    /// without hopping to the main actor (`TerminalController` is `@MainActor`).
    private nonisolated static let settingsControlReadMethods: Set<String> = [
        "settings.control.list",
        "settings.control.get",
        "settings.control.describe",
        "settings.control.export",
        "settings.control.shortcuts.list",
        "settings.control.shortcuts.get",
    ]

    /// Entry point from the socket-worker dispatch switch.
    nonisolated func socketWorkerSettingsControlResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        v2VmCall(id: id, timeoutSeconds: 30) {
            try await self.performSettingsControl(method: method, params: params)
        }
    }

    private nonisolated func performSettingsControl(
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        guard let stores = await MainActor.run(body: { () -> SettingsControlStores? in
            guard let runtime = AppDelegate.shared?.settingsRuntime else { return nil }
            return SettingsControlStores(
                defaults: runtime.userDefaultsStore,
                json: runtime.jsonStore,
                secret: runtime.secretStore
            )
        }) else {
            throw SettingsControlError.storage("settings runtime is not available")
        }

        let engine = SettingsControlEngine(stores: stores)
        let payload = try await Self.dispatchSettingsControl(engine: engine, method: method, params: params)

        if !Self.settingsControlReadMethods.contains(method) {
            // Re-read cmux.json / shortcut bindings so file-backed writes apply
            // live (UserDefaults writes already applied via in-process observers).
            await MainActor.run { self.controlSidebarReloadConfig() }
        }

        return payload
    }

    private nonisolated static func dispatchSettingsControl(
        engine: SettingsControlEngine,
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        switch method {
        case "settings.control.list":
            let rows = await engine.list()
            return ["settings": rows.map(settingRowPayload)]

        case "settings.control.get":
            let row = try await engine.get(requireString(params, "key"))
            return settingRowPayload(row)

        case "settings.control.describe":
            return describePayload(try await engine.describe(requireString(params, "key")))

        case "settings.control.set":
            let row = try await engine.set(requireString(params, "key"), rawValue: requireString(params, "value"))
            return settingRowPayload(row)

        case "settings.control.unset":
            return settingRowPayload(try await engine.unset(requireString(params, "key")))

        case "settings.control.reset":
            if boolParam(params, "all") {
                try await engine.resetAll()
                return ["ok": true]
            }
            return settingRowPayload(try await engine.reset(requireString(params, "key")))

        case "settings.control.export":
            let document = await engine.export()
            return ["settings": document.settings.mapValues { $0.jsonObject }]

        case "settings.control.import":
            let document = try SettingsDocument.parse(requireString(params, "document"))
            try await engine.importDocument(document)
            return ["ok": true, "count": document.settings.count]

        case "settings.control.shortcuts.list":
            let rows = await engine.shortcutsList()
            return ["shortcuts": rows.map(shortcutRowPayload)]

        case "settings.control.shortcuts.get":
            return shortcutRowPayload(try await engine.shortcutGet(requireString(params, "action")))

        case "settings.control.shortcuts.set":
            let row = try await engine.shortcutSet(
                requireString(params, "action"),
                combo: requireString(params, "value"),
                force: boolParam(params, "force")
            )
            return shortcutRowPayload(row)

        case "settings.control.shortcuts.unset":
            return shortcutRowPayload(try await engine.shortcutUnset(requireString(params, "action")))

        case "settings.control.shortcuts.reset":
            try await engine.shortcutsReset()
            return ["ok": true]

        default:
            throw SettingsControlError.storage("unknown settings method '\(method)'")
        }
    }

    // MARK: - Payload encoding

    private nonisolated static func settingRowPayload(_ row: SettingRow) -> [String: Any] {
        [
            "id": row.id,
            "value": row.value.jsonObject,
            "default": row.defaultValue.jsonObject,
            "backend": row.backend.displayName,
            "type": row.valueType.name,
            "overridden": row.isOverridden,
            "secret": row.isSecret,
            "source": row.source,
        ]
    }

    private nonisolated static func describePayload(_ description: SettingDescription) -> [String: Any] {
        var payload: [String: Any] = [
            "id": description.id,
            "backend": description.backend.displayName,
            "type": description.type,
            "secret": description.isSecret,
            "value": description.value.jsonObject,
            "default": description.defaultValue.jsonObject,
            "overridden": description.isOverridden,
            "section": description.section,
        ]
        if let allowed = description.allowedValues {
            payload["allowedValues"] = allowed
        }
        return payload
    }

    private nonisolated static func shortcutRowPayload(_ row: ShortcutRow) -> [String: Any] {
        [
            "action": row.action,
            "binding": row.binding,
            "default": row.defaultBinding,
            "overridden": row.isOverridden,
        ]
    }

    // MARK: - Param helpers

    private nonisolated static func requireString(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else {
            throw SettingsControlError.invalidValue(key: key, reason: "missing required string parameter '\(key)'")
        }
        return value
    }

    private nonisolated static func boolParam(_ params: [String: Any], _ key: String) -> Bool {
        if let bool = params[key] as? Bool { return bool }
        if let number = params[key] as? NSNumber { return number.boolValue }
        return false
    }
}

import AppKit
import CmuxSettings
import Foundation
import WebKit

/// `browser.extension.*` socket verbs for the dev CLI: list, install,
/// uninstall, enable/disable, inspect (permissions/commands/errors), open the
/// action popup, and evaluate JavaScript in an extension's web views. All
/// extension web views are marked inspectable at load, so Safari's Web
/// Inspector (Develop menu) remains the full console; `eval` covers scripted
/// checks the CLI needs.
enum BrowserWebExtensionAutomation {
    static func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard #available(macOS 15.4, *) else {
            throw automationError("unsupported", "Web extensions require macOS 15.4 or later.")
        }
        switch method {
        case "browser.extension.list":
            return try await list()
        case "browser.extension.install":
            return try await install(params: params)
        case "browser.extension.uninstall":
            return try await uninstall(params: params)
        case "browser.extension.set_enabled":
            return try await setEnabled(params: params)
        case "browser.extension.inspect":
            return try await inspect(params: params)
        case "browser.extension.action":
            return try await openActionPopup(params: params)
        case "browser.extension.eval":
            return try await evalJavaScript(params: params)
        default:
            throw automationError("method_not_found", "Unknown browser.extension method: \(method)")
        }
    }

    // MARK: - Verbs

    @MainActor
    @available(macOS 15.4, *)
    private static func list() async throws -> [String: Any] {
        let support = try requireSupport()
        let entries = try await settingsEntries(support)
        var rows: [[String: Any]] = entries.map { entry in
            var row: [String: Any] = [
                "id": entry.id,
                "kind": entry.kind.rawValue,
                "path": entry.path,
                "enabled": entry.enabled,
                "showsToolbarButton": entry.effectiveShowsToolbarButton,
                "loaded": support.loadedByEntryID[entry.id] != nil,
                "source": "settings",
            ]
            if let displayName = entry.displayName { row["displayName"] = displayName }
            if let record = support.loadedByEntryID[entry.id] {
                row["name"] = record.context.webExtension.displayName ?? ""
                row["version"] = record.context.webExtension.displayVersion ?? ""
            }
            if let loadError = support.loadErrorsByEntryID[entry.id] { row["loadError"] = loadError }
            return row
        }
        let settingsIDs = Set(entries.map(\.id))
        for record in support.loadedRecordsInOrder where !settingsIDs.contains(record.entryID) {
            rows.append([
                "id": record.entryID,
                "path": record.entry.path,
                "kind": record.entry.kind.rawValue,
                "enabled": true,
                "loaded": true,
                "source": "environment",
                "name": record.context.webExtension.displayName ?? "",
                "version": record.context.webExtension.displayVersion ?? "",
            ])
        }
        return ["extensions": rows]
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func install(params: [String: Any]) async throws -> [String: Any] {
        let support = try requireSupport()
        guard let rawPath = params["path"] as? String, !rawPath.isEmpty else {
            throw automationError("invalid_params", "Missing required 'path' (an .appex bundle or unpacked extension directory).")
        }
        let path = BrowserWebExtensionEntry.standardizedPath((rawPath as NSString).expandingTildeInPath)
        let kind: BrowserWebExtensionEntry.Kind
        let id: String
        var displayName = params["displayName"] as? String
        if URL(fileURLWithPath: path).pathExtension == "appex" {
            kind = .safariAppExtension
            guard let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier else {
                throw automationError("invalid_params", "Could not read the .appex bundle identifier at \(path).")
            }
            id = bundleID
            if displayName == nil {
                displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            }
        } else {
            kind = .unpackedDirectory
            guard FileManager.default.fileExists(atPath: path + "/manifest.json") else {
                throw automationError("invalid_params", "No manifest.json at \(path); unpacked extensions need one at the directory root.")
            }
            id = path
        }
        let entry = BrowserWebExtensionEntry(
            id: id,
            kind: kind,
            path: path,
            enabled: (params["enabled"] as? Bool) ?? true,
            displayName: displayName
        )
        var entries = try await settingsEntries(support)
        let resourceRoot = entry.standardizedResourceRootPath
        if entries.contains(where: { $0.id == entry.id || $0.standardizedResourceRootPath == resourceRoot }) {
            throw automationError("duplicate", "An extension with the same identity or path is already configured: \(entry.id)")
        }
        entries.append(entry)
        try await saveSettingsEntries(entries, support)
        return ["installed": ["id": entry.id, "kind": entry.kind.rawValue, "path": entry.path]]
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func uninstall(params: [String: Any]) async throws -> [String: Any] {
        let support = try requireSupport()
        let id = try requiredID(params)
        var entries = try await settingsEntries(support)
        guard let index = entries.firstIndex(where: { $0.id == id || $0.path == id }) else {
            throw automationError("not_found", "No configured extension matches '\(id)'. Environment-injected extensions can't be uninstalled here.")
        }
        let removed = entries.remove(at: index)
        try await saveSettingsEntries(entries, support)
        return ["uninstalled": ["id": removed.id, "path": removed.path]]
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func setEnabled(params: [String: Any]) async throws -> [String: Any] {
        let support = try requireSupport()
        let id = try requiredID(params)
        guard let enabled = params["enabled"] as? Bool else {
            throw automationError("invalid_params", "Missing required boolean 'enabled'.")
        }
        var entries = try await settingsEntries(support)
        guard let index = entries.firstIndex(where: { $0.id == id || $0.path == id }) else {
            throw automationError("not_found", "No configured extension matches '\(id)'.")
        }
        entries[index].enabled = enabled
        try await saveSettingsEntries(entries, support)
        return ["id": entries[index].id, "enabled": enabled]
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func inspect(params: [String: Any]) async throws -> [String: Any] {
        let support = try requireSupport()
        let record = try requireLoadedRecord(support, params: params)
        let context = record.context
        var result: [String: Any] = [
            "id": record.entryID,
            "name": context.webExtension.displayName ?? "",
            "version": context.webExtension.displayVersion ?? "",
            "path": record.entry.path,
            "kind": record.entry.kind.rawValue,
            "grantedPermissions": context.grantedPermissions.keys.map(\.rawValue).sorted(),
            "grantedMatchPatterns": context.grantedPermissionMatchPatterns.keys.map { String(describing: $0) }.sorted(),
            "deniedPermissions": context.deniedPermissions.keys.map(\.rawValue).sorted(),
            "requestedPermissions": context.webExtension.requestedPermissions.map(\.rawValue).sorted(),
            "requestedMatchPatterns": context.webExtension.requestedPermissionMatchPatterns.map { String(describing: $0) }.sorted(),
            "commands": context.commands.map { command in
                [
                    "id": command.id,
                    "activationKey": command.activationKey ?? "",
                    "modifierFlags": command.modifierFlags.rawValue,
                ] as [String: Any]
            },
            "manifestErrors": context.webExtension.errors.map(\.localizedDescription),
            "runtimeErrors": context.errors.map { ($0 as NSError).description },
            "hasPopup": context.action(for: support.activeTabAdapter)?.presentsPopup ?? false,
            "inspectable": context.isInspectable,
        ]
        if let loadError = support.loadErrorsByEntryID[record.entryID] { result["loadError"] = loadError }
        return result
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func openActionPopup(params: [String: Any]) async throws -> [String: Any] {
        let support = try requireSupport()
        let record = try requireLoadedRecord(support, params: params)
        guard let panel = support.activeTabAdapter?.panel else {
            throw automationError("no_browser", "No active browser panel to anchor the popup; open/focus a browser pane first.")
        }
        support.performAction(context: record.context, panel: panel, anchorView: nil)
        return ["performed": true, "panel": panel.id.uuidString]
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func evalJavaScript(params: [String: Any]) async throws -> [String: Any] {
        let support = try requireSupport()
        let record = try requireLoadedRecord(support, params: params)
        guard let js = params["js"] as? String, !js.isEmpty else {
            throw automationError("invalid_params", "Missing required 'js' string.")
        }
        let target = (params["target"] as? String) ?? "popup"
        let webView: WKWebView
        switch target {
        case "popup":
            guard let action = record.context.action(for: support.activeTabAdapter), action.presentsPopup else {
                throw automationError("no_popup", "Extension declares no action popup.")
            }
            // Accessing popupWebView preloads the popup page, so eval works
            // without the popover being on screen.
            guard let popupWebView = action.popupWebView else {
                throw automationError("no_popup", "Popup web view is unavailable.")
            }
            webView = popupWebView
        case "background":
#if DEBUG
            // WebKit exposes no public background web view; this private
            // accessor is a DEBUG-build convenience. Safari's Web Inspector is
            // the supported console (extension web views are inspectable).
            let selector = NSSelectorFromString("_backgroundWebView")
            guard record.context.responds(to: selector),
                  let backgroundWebView = record.context.value(forKey: "_backgroundWebView") as? WKWebView else {
                throw automationError("unsupported", "Background page eval is unavailable on this WebKit; attach Safari Web Inspector instead.")
            }
            webView = backgroundWebView
#else
            throw automationError("unsupported", "Background page eval is DEBUG-only; attach Safari Web Inspector instead.")
#endif
        default:
            throw automationError("invalid_params", "Unknown target '\(target)'; expected popup or background.")
        }
        // `async: true` runs `js` as an async function body (use `return` and
        // `await`; promises resolve before the result serializes). The default
        // evaluates a plain expression.
        let runAsAsyncFunction = (params["async"] as? Bool) ?? false
        let raw: Any? = try await withCheckedThrowingContinuation { continuation in
            if runAsAsyncFunction {
                webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                    continuation.resume(with: result.map { $0 as Any? })
                }
            } else {
                webView.evaluateJavaScript(js) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
        }
        return [
            "target": target,
            "url": webView.url?.absoluteString ?? "",
            "result": jsonSafe(raw),
        ]
    }

    // MARK: - Helpers

    @MainActor
    @available(macOS 15.4, *)
    private static func requireSupport() throws -> BrowserWebExtensionSupport {
        guard let support = AppDelegate.shared?.browserWebExtensionHost as? BrowserWebExtensionSupport else {
            throw automationError("unavailable", "The browser web-extension host is not running.")
        }
        return support
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func requireLoadedRecord(
        _ support: BrowserWebExtensionSupport,
        params: [String: Any]
    ) throws -> BrowserWebExtensionLoadedRecord {
        let id = try requiredID(params)
        guard let record = support.loadedRecordsInOrder.first(where: {
            $0.entryID == id || $0.entry.path == id || ($0.context.webExtension.displayName ?? "").localizedCaseInsensitiveContains(id)
        }) else {
            let loaded = support.loadedRecordsInOrder.map(\.entryID).joined(separator: ", ")
            throw automationError("not_found", "No loaded extension matches '\(id)'. Loaded: [\(loaded)]")
        }
        return record
    }

    private static func requiredID(_ params: [String: Any]) throws -> String {
        guard let id = params["id"] as? String, !id.isEmpty else {
            throw automationError("invalid_params", "Missing required 'id' (entry id, path, or display-name substring).")
        }
        return id
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func settingsEntries(_ support: BrowserWebExtensionSupport) async throws -> [BrowserWebExtensionEntry] {
        guard let store = support.settingsStore, let key = support.settingsKey else {
            throw automationError("unavailable", "Extension settings are not configured.")
        }
        return await store.value(for: key)
    }

    @MainActor
    @available(macOS 15.4, *)
    private static func saveSettingsEntries(
        _ entries: [BrowserWebExtensionEntry],
        _ support: BrowserWebExtensionSupport
    ) async throws {
        guard let store = support.settingsStore, let key = support.settingsKey else {
            throw automationError("unavailable", "Extension settings are not configured.")
        }
        try await store.set(entries, for: key)
    }

    private static func jsonSafe(_ value: Any?) -> Any {
        switch value {
        case nil:
            return NSNull()
        case let value as NSNumber:
            return value
        case let value as String:
            return value
        case let value as [Any]:
            return value.map { jsonSafe($0) }
        case let value as [String: Any]:
            return value.mapValues { jsonSafe($0) }
        case let value as Date:
            return ISO8601DateFormatter().string(from: value)
        case let value?:
            return String(describing: value)
        }
    }

    private static func automationError(_ code: String, _ message: String) -> NSError {
        NSError(
            domain: "cmux.webExtension.automation",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "\(code): \(message)",
            ]
        )
    }
}

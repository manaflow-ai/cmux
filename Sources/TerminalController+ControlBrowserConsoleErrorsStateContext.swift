import AppKit
import CmuxControlSocket
import Foundation
import WebKit

/// The live-app half of the non-JS-eval-worker-lane, main-actor browser
/// telemetry + session-state commands (`browser.console.list`,
/// `browser.console.clear`, `browser.errors.list`, `browser.state.save`,
/// `browser.state.load`). The coordinator owns the param parsing and `JSONValue`
/// payload shaping; these witnesses perform the `TabManager` / `Workspace` /
/// `BrowserPanel` reach plus the telemetry-hook bootstrap, the console/error ring
/// read/clear JS, the cookie/storage read+write, and the JSON state-file I/O,
/// byte-faithful to the former `v2BrowserConsoleList` / `v2BrowserConsoleClear` /
/// `v2BrowserErrorsList` / `v2BrowserStateSave` / `v2BrowserStateLoad` bodies.
///
/// The shared `v2BrowserWithPanel`-head resolution is reproduced by
/// `browserResolvePanelTyped(params:)` (declared in
/// `TerminalController+ControlBrowserCookiesStorageContext.swift`), which
/// surfaces each failure category as a typed value the coordinator maps back to
/// the exact legacy `.err`.
///
/// These witnesses stay on `TerminalController` (rather than moving the bodies
/// into the `@MainActor` coordinator) because they touch the `private`
/// telemetry-hook bootstrap (`v2BrowserEnsureTelemetryHooks`) and the per-surface
/// frame-selector state (`v2BrowserSurfaceState`, a `BrowserAutomationSurfaceState`
/// in `CmuxBrowser`), which is also read by the out-of-scope worker-lane JS-eval
/// methods through `v2BrowserCurrentFrameSelector`; those bodies cannot move into
/// the coordinator without breaking that reader.
extension TerminalController {
    // MARK: - console.list / console.clear

    func controlBrowserConsoleList(
        params: [String: JSONValue],
        clear: Bool
    ) -> ControlBrowserConsoleListResolution {
        let foundation = params.mapValues(\.foundationObject)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            v2BrowserEnsureTelemetryHooks(surfaceId: resolved.surfaceId, browserPanel: resolved.browserPanel)
            let script = v2BrowserControl.consoleLogReadScript(clear: clear)
            switch v2RunJavaScript(resolved.browserPanel.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                // `.map` (not `.compactMap`): preserve the legacy element count
                // (`count: items.count`); `v2NormalizeJSValue` yields JSON-safe
                // Foundation values so the bridge never fails, and a `.null`
                // fallback keeps the one-to-one mapping byte-faithful.
                let entries = items.map(v2NormalizeJSValue).map { JSONValue(foundationObject: $0) ?? .null }
                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: resolved.surfaceId,
                    entries: entries
                )
            }
        }
    }

    // MARK: - errors.list

    func controlBrowserErrorsList(
        params: [String: JSONValue],
        clear: Bool
    ) -> ControlBrowserErrorsListResolution {
        let foundation = params.mapValues(\.foundationObject)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            v2BrowserEnsureTelemetryHooks(surfaceId: resolved.surfaceId, browserPanel: resolved.browserPanel)
            let script = v2BrowserControl.errorLogReadScript(clear: clear)
            switch v2RunJavaScript(resolved.browserPanel.webView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                // `.map` (not `.compactMap`): preserve the legacy element count
                // (`count: items.count`); `v2NormalizeJSValue` yields JSON-safe
                // Foundation values so the bridge never fails, and a `.null`
                // fallback keeps the one-to-one mapping byte-faithful.
                let errors = items.map(v2NormalizeJSValue).map { JSONValue(foundationObject: $0) ?? .null }
                return .resolved(
                    workspaceID: resolved.workspace.id,
                    surfaceID: resolved.surfaceId,
                    errors: errors
                )
            }
        }
    }

    // MARK: - state.save

    func controlBrowserStateSave(
        params: [String: JSONValue],
        path: String
    ) -> ControlBrowserStateSaveResolution {
        let foundation = params.mapValues(\.foundationObject)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let surfaceId = resolved.surfaceId
            let browserPanel = resolved.browserPanel
            let storageScript = v2BrowserControl.storageSnapshotScript()

            let storageValue: Any
            switch v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: storageScript, timeout: 10.0) {
            case .failure(let message):
                return .jsError(message: message)
            case .success(let value):
                storageValue = v2NormalizeJSValue(value)
            }

            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let cookies = (v2BrowserCookieRepository.allCookies(in: store) ?? []).map(v2BrowserCookieRepository.cookieDictionary(from:))

            let state: [String: Any] = [
                "url": browserPanel.currentURL?.absoluteString ?? "",
                "cookies": cookies,
                "storage": storageValue,
                "frame_selector": v2OrNull(v2BrowserSurfaceState.frameSelector(surfaceId: surfaceId))
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .writeFailed(path: path, error: error.localizedDescription)
            }

            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: surfaceId,
                path: path,
                cookieCount: cookies.count
            )
        }
    }

    // MARK: - state.load

    func controlBrowserStateLoad(
        params: [String: JSONValue],
        path: String
    ) -> ControlBrowserStateLoadResolution {
        let url = URL(fileURLWithPath: path)
        let raw: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .notObject(path: path)
            }
            raw = obj
        } catch {
            return .readFailed(path: path, error: error.localizedDescription)
        }

        let foundation = params.mapValues(\.foundationObject)
        switch browserResolvePanelTyped(params: foundation) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let resolved):
            let surfaceId = resolved.surfaceId
            let browserPanel = resolved.browserPanel

            if let frameSelector = raw["frame_selector"] as? String, !frameSelector.isEmpty {
                v2BrowserSurfaceState.setFrameSelector(frameSelector, surfaceId: surfaceId)
            } else {
                v2BrowserSurfaceState.clearFrameSelector(surfaceId: surfaceId)
            }

            if let urlStr = raw["url"] as? String,
               !urlStr.isEmpty,
               let parsed = URL(string: urlStr) {
                browserPanel.navigate(to: parsed)
            }

            if let cookieRows = raw["cookies"] as? [[String: Any]] {
                let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
                for row in cookieRows {
                    if let cookie = v2BrowserCookieRepository.cookie(from: row, fallbackURL: browserPanel.currentURL) {
                        _ = v2BrowserCookieRepository.setCookie(cookie, in: store)
                    }
                }
            }

            if let storage = raw["storage"] as? [String: Any] {
                let storageLiteral = v2JSONLiteral(storage)
                let script = v2BrowserControl.storageRestoreScript(storageLiteral: storageLiteral)
                _ = v2RunBrowserJavaScript(v2MainSync { browserPanel.webView }, surfaceId: surfaceId, script: script, timeout: 10.0)
            }

            return .resolved(
                workspaceID: resolved.workspace.id,
                surfaceID: surfaceId,
                path: path
            )
        }
    }
}

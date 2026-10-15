import CmuxBrowser
import Foundation

/// The `engine` parameter of browser-creating socket methods
/// (`browser.open_split`, `browser.tab.new`) and the `engine` field their
/// results report.
///
/// An explicit engine the app cannot open is refused with the reason, never
/// silently replaced by WebKit, so a script that asked for Chromium knows it
/// did not get it (engine decision E2, same as cmux Next).
extension TerminalController {
    /// The engine named by the `engine` parameter, nil when absent.
    nonisolated func v2BrowserRequestedEngine(
        _ params: [String: Any]
    ) -> (engine: BrowserEngineKind?, error: V2CallResult?) {
        guard v2HasNonNullParam(params, "engine") else { return (nil, nil) }
        guard let raw = params["engine"] as? String,
              let engine = BrowserEngineKind(requestValue: raw) else {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.engine.error.invalid",
                    defaultValue: "Choose WebKit or Chromium for the browser engine."
                ),
                data: ["engine": params["engine"].map { "\($0)" } ?? NSNull()]
            ))
        }
        return (engine, nil)
    }

    /// Why a WebKit panel is not on the engine it wanted (`CMUX_BROWSER_ENGINE`,
    /// an inherited engine or `browser.engine` named one that could not open,
    /// or its Chromium runtime failed to start); nil otherwise, including for
    /// an explicit `--engine webkit`.
    @MainActor
    func v2BrowserEngineFallbackReason(_ panel: BrowserPanel) -> BrowserEngineUnavailableReason? {
        // The panel records why it is WebKit although Chromium was wanted
        // (at creation or after a start failure).
        panel.activeEngineKind == .webkit ? panel.engineFallbackReason : nil
    }

    /// The `engine` (and, after a fallback, `engine_fallback_reason`) fields
    /// browser results carry, so a script can tell which engine it drives.
    @MainActor
    func v2BrowserEngineFields(
        _ panel: BrowserPanel,
        requested: BrowserEngineKind? = nil,
        runtime: BrowserEngineRuntime = .shared
    ) -> [String: Any] {
        var fields: [String: Any] = ["engine": panel.activeEngineKind.rawValue]
        if let requested, requested != panel.activeEngineKind {
            // An explicit engine that resolved but then could not create the
            // page (its runtime failed to start) renders WebKit: say why,
            // never report the requested engine.
            let reason = panel.engineFallbackReason
                ?? runtime.availability(for: requested).unavailableReason
                ?? .startFailed("page creation failed")
            fields["engine_fallback_reason"] = reason.code
            if let detail = reason.detail {
                fields["engine_fallback_detail"] = detail
            }
        } else if let reason = v2BrowserEngineFallbackReason(panel) {
            fields["engine_fallback_reason"] = reason.code
        }
        return fields
    }

    /// The panel's non-WebKit engine page, or nil for a WebKit panel. The
    /// engine is fixed at panel creation, so a WebKit panel answers without a
    /// main-thread hop and its automation paths cost nothing extra.
    nonisolated func v2EnginePage(_ panel: BrowserPanel) -> (any BrowserPage)? {
        guard panel.engineKind != .webkit else { return nil }
        return v2MainSync { panel.automationEnginePage }
    }

    /// The refusal for scripting, input, cookies or screenshots on a page an
    /// agent may not drive: a Chromium internal page (settings, passwords,
    /// extensions, DevTools) the person opened in the panel. Nil when the
    /// agent may drive it, and always for WebKit panels.
    @MainActor
    func v2EngineAgentRefusal(_ panel: BrowserPanel, surfaceId: UUID) -> V2CallResult? {
        guard !panel.agentMayDriveCurrentPage else { return nil }
        return .err(
            code: "agent_refused",
            message: String(
                localized: "browser.automation.error.internalPageRefused",
                defaultValue: "Agents can't script or send input to this browser's internal pages"
            ),
            data: [
                "surface_id": surfaceId.uuidString,
                "url": panel.currentURL?.absoluteString ?? "",
            ]
        )
    }

    /// `v2EngineAgentRefusal` from the socket worker.
    nonisolated func v2EngineAgentRefusalOnWorker(_ panel: BrowserPanel, surfaceId: UUID) -> V2CallResult? {
        v2MainSync { v2EngineAgentRefusal(panel, surfaceId: surfaceId) }
    }

    /// Modifier keys automation holds down per engine surface (DevTools key
    /// events carry no keyboard state of their own).
    @MainActor private static var v2EngineHeldModifiers: [UUID: BrowserAutomationHeldModifiers] = [:]

    /// Records one automation key action on an engine surface and returns the
    /// modifiers to send with it, so `keydown Shift` then `press a` types `A`.
    @MainActor
    func v2EngineKeyModifiers(
        surfaceId: UUID,
        event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) -> BrowserKeyboardNativeModifiers {
        var state = Self.v2EngineHeldModifiers[surfaceId] ?? BrowserAutomationHeldModifiers()
        let modifiers = state.record(event, action: action)
        Self.v2EngineHeldModifiers[surfaceId] = state.held.isEmpty ? nil : state
        return modifiers
    }

    /// Runs one engine-page operation on the main actor and waits for it on
    /// the socket worker, at most `timeout` seconds. Nil when it did not finish
    /// in time (the operation is then cancelled).
    nonisolated func v2AwaitEnginePage<T>(
        timeout: TimeInterval,
        _ operation: @escaping @MainActor () async -> T
    ) -> T? {
        var task: Task<Void, Never>?
        let outcome: T? = v2AwaitCallback(timeout: max(0.01, timeout)) { finish in
            task = Task { @MainActor in
                finish(await operation())
            }
        }
        if outcome == nil {
            task?.cancel()
        }
        return outcome
    }

    /// The socket error text for an engine-page automation failure.
    nonisolated static func v2EngineAutomationMessage(_ error: any Error) -> String {
        if let error = error as? BrowserAutomationPageError {
            return error.message
        }
        return error.localizedDescription
    }

    /// The socket error for an engine-page automation failure.
    nonisolated func v2EngineAutomationError(_ error: any Error, surfaceId: UUID) -> V2CallResult {
        let code: String
        let data: [String: Any] = ["surface_id": surfaceId.uuidString]
        switch error as? BrowserAutomationPageError {
        case .javaScript: code = "js_error"
        case .pageUnavailable(let reason):
            return v2EnginePageUnavailable(reason, surfaceId: surfaceId)
        case .unsupported: code = "not_supported"
        default: code = "internal_error"
        }
        return .err(code: code, message: Self.v2EngineAutomationMessage(error), data: data)
    }

    /// The one error every browser command returns when a Chromium surface's
    /// page cannot run: `engine_unavailable`, with the engine's reason
    /// (`notBundled`, `startFailed` with its detail, `shutDown`) when it has
    /// one, or `pageClosed` when only this page is gone.
    nonisolated func v2EnginePageUnavailable(
        _ reason: BrowserEngineUnavailableReason?,
        surfaceId: UUID?
    ) -> V2CallResult {
        var data: [String: Any] = [
            "surface_id": surfaceId.map { $0.uuidString as Any } ?? NSNull(),
            "engine": BrowserEngineKind.chromium.rawValue,
            "reason": reason?.code ?? "pageClosed",
        ]
        if let detail = reason?.detail {
            data["detail"] = detail
        }
        return .err(
            code: "engine_unavailable",
            message: BrowserAutomationPageError.pageUnavailable(reason).message,
            data: data
        )
    }

    /// Thread-local side channel: a script-backed command on an engine page
    /// records here that the page could not run, so the socket-worker
    /// dispatcher can answer `engine_unavailable` instead of the command's
    /// own `js_error` wrapping. Each command runs synchronously on one
    /// worker thread.
    private static let v2EngineUnavailableThreadKey = "cmux.automation.engineUnavailable"

    nonisolated func v2RecordEnginePageUnavailable(_ reason: BrowserEngineUnavailableReason?, surfaceId: UUID?) {
        Thread.current.threadDictionary[Self.v2EngineUnavailableThreadKey] = V2EngineUnavailableRecord(
            reason: reason,
            surfaceId: surfaceId
        )
    }

    /// Rewrites a failed command's error to `engine_unavailable` when its
    /// engine page could not run during the command; clears the record.
    nonisolated func v2ApplyEnginePageUnavailable(_ result: V2CallResult) -> V2CallResult {
        let dictionary = Thread.current.threadDictionary
        guard let record = dictionary[Self.v2EngineUnavailableThreadKey] as? V2EngineUnavailableRecord else {
            return result
        }
        dictionary.removeObject(forKey: Self.v2EngineUnavailableThreadKey)
        guard case .err = result else { return result }
        return v2EnginePageUnavailable(record.reason, surfaceId: record.surfaceId)
    }

    /// Clears a stale record before a command runs.
    nonisolated func v2ClearEnginePageUnavailable() {
        Thread.current.threadDictionary.removeObject(forKey: Self.v2EngineUnavailableThreadKey)
    }

    /// The error for an engine-page operation that did not finish in time.
    nonisolated func v2EngineAutomationTimeout(surfaceId: UUID) -> V2CallResult {
        .err(
            code: "timeout",
            message: String(
                localized: "browser.automation.error.engineTimedOut",
                defaultValue: "Timed out waiting for the browser engine"
            ),
            data: ["surface_id": surfaceId.uuidString]
        )
    }

    /// The refusal for an explicitly requested engine that cannot open, or
    /// nil when the request can be honored.
    ///
    /// The app's engine runtime decides: Chromium is available once its
    /// provider is registered (the runtime is bundled and started).
    @MainActor
    func v2BrowserEngineRefusal(
        _ requested: BrowserEngineKind?,
        runtime: BrowserEngineRuntime = .shared
    ) -> V2CallResult? {
        guard let requested,
              case .refuse(let engine, let reason) = runtime.resolve(requested: requested) else {
            return nil
        }
        var data: [String: Any] = ["engine": engine.rawValue, "reason": reason.code]
        if let detail = reason.detail {
            data["detail"] = detail
        }
        return .err(
            code: "engine_unavailable",
            message: String(
                localized: "cli.browser.engine.error.chromiumUnavailable",
                defaultValue: "The Chromium browser engine is not available"
            ) + " (\(reason.code))",
            data: data
        )
    }

    /// Dock browsers open with WebKit only; an explicit other engine is
    /// refused there.
    nonisolated func v2BrowserEngineUnsupportedInDock(_ engine: BrowserEngineKind) -> V2CallResult {
        .err(
            code: "not_supported",
            message: String(
                localized: "cli.browser.engine.error.dockUnsupported",
                defaultValue: "Dock browsers use WebKit; open the page in a workspace pane to use another engine"
            ),
            data: ["engine": engine.rawValue]
        )
    }
}

/// An engine page that could not run during the current socket command.
private final class V2EngineUnavailableRecord {
    let reason: BrowserEngineUnavailableReason?
    let surfaceId: UUID?

    init(reason: BrowserEngineUnavailableReason?, surfaceId: UUID?) {
        self.reason = reason
        self.surfaceId = surfaceId
    }
}

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

    /// Whether this app can open Chromium browser panels now.
    ///
    /// Chromium is available only once the engine integration registers a
    /// Chromium provider; this build has none, so it reports the runtime as
    /// not bundled.
    @MainActor
    func v2BrowserChromiumAvailability() -> BrowserEngineAvailability {
        .unavailable(.notBundled)
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
        switch error as? BrowserAutomationPageError {
        case .javaScript: code = "js_error"
        case .pageUnavailable: code = "unavailable"
        case .unsupported: code = "not_supported"
        default: code = "internal_error"
        }
        return .err(
            code: code,
            message: Self.v2EngineAutomationMessage(error),
            data: ["surface_id": surfaceId.uuidString]
        )
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
    @MainActor
    func v2BrowserEngineRefusal(_ requested: BrowserEngineKind?) -> V2CallResult? {
        guard requested == .chromium else { return nil }
        guard case .unavailable(let reason) = v2BrowserChromiumAvailability() else { return nil }
        var data: [String: Any] = ["engine": BrowserEngineKind.chromium.rawValue, "reason": reason.code]
        if let detail = reason.detail {
            data["detail"] = detail
        }
        return .err(
            code: "engine_unavailable",
            message: String(
                localized: "cli.browser.engine.error.chromiumUnavailable",
                defaultValue: "Chromium is not available in this build of cmux"
            ),
            data: data
        )
    }
}

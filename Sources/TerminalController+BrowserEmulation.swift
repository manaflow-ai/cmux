import CmuxBrowser
import Foundation

/// `browser.geolocation.set` and `browser.offline.set` on WebKit panels.
///
/// Both run on the socket worker: offline mode compiles a content rule list
/// before it applies, and the reply waits until the override is in place, so
/// a following `browser.navigate` or `browser.eval` already sees it.
extension TerminalController {
    nonisolated func v2BrowserGeolocationSet(params: [String: Any]) -> V2CallResult {
        let geolocation: BrowserGeolocationOverride?
        if v2Bool(params, "clear") == true {
            geolocation = nil
        } else {
            guard let latitude = v2Double(params, "latitude"),
                  let longitude = v2Double(params, "longitude") else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "cli.browser.geolocation.invalidParams",
                        defaultValue: "browser.geolocation.set needs latitude and longitude, or clear: true"
                    ),
                    data: nil
                )
            }
            guard let position = BrowserGeolocationOverride(
                latitude: latitude,
                longitude: longitude,
                accuracy: v2Double(params, "accuracy") ?? 0
            ) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "cli.browser.geolocation.outOfRange",
                        defaultValue: "Latitude must be between -90 and 90, longitude between -180 and 180, and accuracy 0 or more"
                    ),
                    data: ["latitude": latitude, "longitude": longitude]
                )
            }
            geolocation = position
        }
        return v2BrowserUpdateEmulation(params: params) { $0.geolocation = geolocation }
    }

    nonisolated func v2BrowserOfflineSet(params: [String: Any]) -> V2CallResult {
        guard let enabled = v2Bool(params, "enabled") ?? v2Bool(params, "offline") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.offline.invalidParams",
                    defaultValue: "browser.offline.set needs enabled: true or false"
                ),
                data: nil
            )
        }
        return v2BrowserUpdateEmulation(params: params) { $0.offline = enabled }
    }

    private nonisolated func v2BrowserUpdateEmulation(
        params: [String: Any],
        _ change: @escaping @Sendable (inout BrowserEmulationOverrides) -> Void
    ) -> V2CallResult {
        v2BrowserWithPanelContext(params: params) { context in
            let panel = context.browserPanel
            var applyTask: Task<Void, Never>?
            let outcome: Result<BrowserEmulationOverrides, BrowserEmulationError>? = v2AwaitCallback(timeout: 10) { finish in
                applyTask = Task { @MainActor in
                    do {
                        finish(.success(try await panel.updateBrowserEmulation(change)))
                    } catch let error as BrowserEmulationError {
                        finish(.failure(error))
                    } catch {
                        finish(.failure(.offlineRulesUnavailable))
                    }
                }
            }
            switch outcome {
            case nil:
                // Cancelling before the rules compile keeps the change from
                // landing after the client was told it timed out.
                applyTask?.cancel()
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.browser.emulation.timeout",
                        defaultValue: "Timed out applying browser emulation"
                    ),
                    data: nil
                )
            case .failure(.superseded):
                return .err(
                    code: "stale_state",
                    message: String(
                        localized: "browser.automation.error.superseded",
                        defaultValue: "The browser surface was already recovered. Retry the command."
                    ),
                    data: v2BrowserPanelFields(context)
                )
            case .failure(.offlineRulesUnavailable):
                return .err(
                    code: "emulation_failed",
                    message: String(
                        localized: "cli.browser.emulation.offlineFailed",
                        defaultValue: "The browser could not turn on offline mode"
                    ),
                    data: v2BrowserPanelFields(context)
                )
            case .success(let overrides):
                var fields: [String: Any] = ["offline": overrides.offline]
                if let position = overrides.geolocation {
                    fields["geolocation"] = [
                        "latitude": position.latitude,
                        "longitude": position.longitude,
                        "accuracy": position.accuracy,
                    ]
                } else {
                    fields["geolocation"] = NSNull()
                }
                return .ok(v2BrowserPanelFields(context, adding: fields))
            }
        }
    }
}

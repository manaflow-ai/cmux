import CmuxBrowser
import Foundation

/// `browser.console.list`, `browser.errors.list` and `browser.network.requests`
/// on Chromium surfaces read the page's DevTools protocol events
/// (`BrowserPanel+ProtocolTelemetry`). WebKit surfaces keep their JavaScript
/// bootstrap logs, and `browser.network.requests` stays not_supported there.
extension TerminalController {
    /// The Chromium page's recorded events once every event delivered so far
    /// was handled; nil for WebKit panels or when the page did not answer.
    nonisolated func v2EngineProtocolTelemetry(_ panel: BrowserPanel) -> BrowserProtocolTelemetryRecorder? {
        guard panel.engineKind != .webkit else { return nil }
        let outcome: BrowserProtocolTelemetryRecorder?? = v2AwaitEnginePage(timeout: 5.0) {
            guard let page = panel.protocolTelemetryPage else { return nil }
            page.startProtocolTelemetry()
            await page.protocolTelemetryReady()
            return page.protocolTelemetry
        }
        return outcome ?? nil
    }

    /// Clears the Chromium page's recorded logs; nothing for WebKit panels.
    nonisolated func v2EngineClearProtocolTelemetry(
        _ panel: BrowserPanel,
        console: Bool = false,
        errors: Bool = false,
        network: Bool = false
    ) {
        guard panel.engineKind != .webkit else { return }
        v2MainSync {
            panel.protocolTelemetryPage?.clearProtocolTelemetry(console: console, errors: errors, network: network)
        }
    }

    /// `browser.network.requests` of a Chromium surface: the requests its page
    /// made since recording started, oldest first. Nil when the surface is
    /// not a Chromium page (the caller answers not_supported).
    func v2EngineNetworkRequests(params: [String: Any]) -> V2CallResult? {
        guard let tabManager = v2ResolveTabManager(params: params),
              let context = v2ResolveBrowserPanelContext(params: params, tabManager: tabManager).context,
              let page = context.browserPanel.protocolTelemetryPage else { return nil }
        page.startProtocolTelemetry()
        let telemetry = page.protocolTelemetry
        let requests = telemetry.networkRequests.map(\.jsonObject)
        if v2Bool(params, "clear") == true {
            page.clearProtocolTelemetry(console: false, errors: false, network: true)
        }
        var fields: [String: Any] = ["requests": requests, "count": requests.count]
        if let started = telemetry.recordingStartedAtMS {
            fields["recording_started_at_ms"] = started
        }
        return .ok(v2BrowserPanelFields(context, adding: fields))
    }
}

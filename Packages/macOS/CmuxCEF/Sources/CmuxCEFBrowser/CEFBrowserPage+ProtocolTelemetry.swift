public import CmuxBrowser
import CmuxCEF
import Foundation

/// Network requests, console messages and page errors for automation, from
/// the page's DevTools protocol events.
///
/// Nothing runs until automation asks: then the shim forwards the browser's
/// protocol events (`cmux_shim_devtools_watch_events`) and the `Network` and
/// `Runtime` domains are enabled. `Runtime.enable` replays the console
/// messages and errors the document logged before, so they are not lost to a
/// late start; requests are recorded from the start on. A browser Chromium
/// creates later for the page (Memory Saver restore) is enabled before its
/// first load.
extension CEFBrowserPage: BrowserPageProtocolTelemetry {
    /// The domains whose events are recorded, enabled in this order.
    nonisolated static let protocolTelemetryMethods = ["Network.enable", "Runtime.enable"]

    public func startProtocolTelemetry() {
        guard !telemetry.wanted else { return }
        telemetry.wanted = true
        telemetry.recorder.recordingStartedAtMS = Date().timeIntervalSince1970 * 1000
        if let id = browser.browserID { enableProtocolTelemetryIfWanted(browserID: id) }
    }

    public func protocolTelemetryReady() async {
        guard telemetry.wanted, browser.browserID != nil else { return }
        // Replies follow the events sent before them: once this answers, the
        // events of the enable calls (the replayed messages) were handled.
        _ = try? await browser.devTools(method: "Runtime.enable")
    }

    public var protocolTelemetry: BrowserProtocolTelemetryRecorder { telemetry.recorder }

    public func clearProtocolTelemetry(console: Bool, errors: Bool, network: Bool) {
        if console { telemetry.recorder.clearConsole() }
        if errors { telemetry.recorder.clearErrors() }
        if network { telemetry.recorder.clearNetwork() }
    }

    /// Turns the shim's event forwarding and the recorded domains on for
    /// browser `id` once per browser, synchronously (before a first load).
    func enableProtocolTelemetryIfWanted(browserID id: Int32) {
        guard telemetry.wanted, telemetry.enabledBrowserID != id, let shim = shimProvider() else { return }
        telemetry.enabledBrowserID = id
        shim.devToolsWatchEvents(id, 1)
        for method in Self.protocolTelemetryMethods {
            _ = shim.devToolsCall(id, method, "{}")
        }
    }

    /// One raw protocol message of the page (`CMUX_SHIM_DEVTOOLS_EVENT`).
    func receiveProtocolMessage(_ json: String) {
        guard telemetry.wanted else { return }
        telemetry.recorder.ingest(json)
    }
}

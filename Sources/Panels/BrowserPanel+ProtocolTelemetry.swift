import CmuxBrowser
import Foundation

/// DevTools protocol telemetry (network requests, console messages, page
/// errors) of a Chromium panel's page, for automation.
///
/// Recording starts the first time automation drives the panel: when an
/// automation command resolves its surface, or when automation opened or
/// took over the panel (dialog owner `.automation`). A page automation opened
/// records from its first document; a page a person opened records requests
/// from that point, and its console and errors from the document's start
/// (`Runtime.enable` replays them). WebKit panels never record.
extension BrowserPanel {
    /// The page as a telemetry source; nil for WebKit panels.
    var protocolTelemetryPage: (any BrowserPageProtocolTelemetry)? {
        automationEnginePage as? any BrowserPageProtocolTelemetry
    }

    /// Starts recording when the page can (idempotent).
    func startAutomationProtocolTelemetry() {
        protocolTelemetryPage?.startProtocolTelemetry()
    }
}

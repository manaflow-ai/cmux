import Foundation

/// A page that records DevTools protocol events for automation: network
/// requests, console messages and page errors (Chromium).
///
/// Recording is off until automation asks (``startProtocolTelemetry()``), so
/// a page nobody automates pays nothing. Once on, it stays on for the page's
/// life; a page whose engine browser is recreated turns it on again.
@MainActor
public protocol BrowserPageProtocolTelemetry: AnyObject {
    /// Turns recording on (idempotent). Takes effect before the first load
    /// when the engine browser does not exist yet.
    func startProtocolTelemetry()
    /// Returns once the engine delivered every event sent before the call,
    /// including the console messages and errors `Runtime.enable` replays.
    func protocolTelemetryReady() async
    /// What was recorded.
    var protocolTelemetry: BrowserProtocolTelemetryRecorder { get }
    /// Clears the chosen logs.
    func clearProtocolTelemetry(console: Bool, errors: Bool, network: Bool)
}

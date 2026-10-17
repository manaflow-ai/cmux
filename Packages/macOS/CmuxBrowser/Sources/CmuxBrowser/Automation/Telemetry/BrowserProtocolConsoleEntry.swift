import Foundation

/// One console message a Chromium page logged (`Runtime.consoleAPICalled`),
/// in the shape of the JavaScript bootstrap's `window.__cmuxConsoleLog`.
public struct BrowserProtocolConsoleEntry: Equatable, Sendable {
    /// `log`, `info`, `warn`, `error` or `debug`, as the bootstrap names them.
    public var level: String
    /// The arguments as text, joined by spaces.
    public var text: String
    /// Milliseconds since 1970.
    public var timestampMS: Double

    public init(level: String, text: String, timestampMS: Double) {
        self.level = level
        self.text = text
        self.timestampMS = timestampMS
    }

    /// The `browser.console.list` item.
    public var jsonObject: [String: Any] {
        ["level": level, "text": text, "timestamp_ms": timestampMS]
    }
}

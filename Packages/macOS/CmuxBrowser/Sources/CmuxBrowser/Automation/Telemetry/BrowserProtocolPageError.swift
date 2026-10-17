import Foundation

/// One uncaught exception or unhandled rejection of a Chromium page
/// (`Runtime.exceptionThrown`), in the shape of the JavaScript bootstrap's
/// `window.__cmuxErrorLog`.
public struct BrowserProtocolPageError: Equatable, Sendable {
    /// As the page's `ErrorEvent.message`: `Uncaught Error: boom`.
    public var message: String
    /// The script URL, empty when unknown.
    public var source: String
    /// 1-based line, 0 when unknown.
    public var line: Int
    /// 1-based column, 0 when unknown.
    public var column: Int
    /// Milliseconds since 1970.
    public var timestampMS: Double
    /// The protocol's exception id (`Runtime.exceptionRevoked` names it).
    public var exceptionID: Int?

    public init(message: String, source: String, line: Int, column: Int, timestampMS: Double, exceptionID: Int? = nil) {
        self.message = message
        self.source = source
        self.line = line
        self.column = column
        self.timestampMS = timestampMS
        self.exceptionID = exceptionID
    }

    /// The `browser.errors.list` item.
    public var jsonObject: [String: Any] {
        ["message": message, "source": source, "line": line, "column": column, "timestamp_ms": timestampMS]
    }
}

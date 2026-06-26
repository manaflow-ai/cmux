public import Foundation

/// One human-readable, redacted app event retained for mobile diagnostics.
public struct MobileDiagnosticsEvent: Sendable, Equatable {
    /// When the event happened.
    public var date: Date
    /// Stable event name, such as `auth.signedIn` or `conn.error`.
    public var name: String
    /// Small redacted key/value payload for the event.
    public var fields: [String: String]

    /// Create a diagnostics event.
    ///
    /// - Parameters:
    ///   - date: When the event happened.
    ///   - name: Stable event name.
    ///   - fields: Small redacted key/value payload for the event.
    public init(date: Date, name: String, fields: [String: String] = [:]) {
        self.date = date
        self.name = name
        self.fields = fields
    }
}

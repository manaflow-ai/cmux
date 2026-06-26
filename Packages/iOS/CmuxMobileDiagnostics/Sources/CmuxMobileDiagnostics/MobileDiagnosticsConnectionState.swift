public import Foundation

/// Redacted connection state included in a mobile diagnostics report.
public struct MobileDiagnosticsConnectionState: Sendable, Equatable {
    /// The current high-level connection state.
    public var state: String
    /// The current connected host label, if available.
    public var host: String?
    /// The most recent connection error message, if available.
    public var lastError: String?

    /// Create a connection-state snapshot.
    ///
    /// - Parameters:
    ///   - state: The current high-level connection state.
    ///   - host: The current connected host label.
    ///   - lastError: The most recent connection error message.
    public init(state: String, host: String? = nil, lastError: String? = nil) {
        self.state = state
        self.host = host
        self.lastError = lastError
    }
}

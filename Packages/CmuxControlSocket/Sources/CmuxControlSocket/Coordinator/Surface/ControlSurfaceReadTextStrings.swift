/// The app-bundle-resolved localized terminal read error strings.
///
/// The app resolves these before handing them to the package coordinator so
/// `String(localized:)` uses the app bundle, not the package bundle.
public struct ControlSurfaceReadTextStrings: Sendable, Equatable {
    /// The `terminal_not_ready` message.
    public let terminalNotReady: String

    /// Creates the read-text strings.
    ///
    /// - Parameter terminalNotReady: The `terminal_not_ready` message.
    public init(terminalNotReady: String) {
        self.terminalNotReady = terminalNotReady
    }
}

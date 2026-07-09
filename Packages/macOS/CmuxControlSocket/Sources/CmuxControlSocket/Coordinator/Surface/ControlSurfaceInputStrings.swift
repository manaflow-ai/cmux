internal import Foundation

/// The app-bundle-resolved localized terminal-input error strings, shared by
/// `surface.send_text` and `surface.send_key`.
///
/// Lifted from the legacy `TerminalController` static `terminal*Message`
/// computed properties (each a `String(localized:)`). They MUST resolve in the app
/// conformance (app bundle): inside the package `String(localized:)` binds to the
/// package bundle, which lacks the keys and silently drops the Japanese
/// translation (a wire change). The app resolves them and passes them through.
public struct ControlSurfaceInputStrings: Sendable, Equatable {
    /// The `input_queue_full` message.
    public let inputQueueFull: String
    /// The `surface_unavailable` message.
    public let surfaceUnavailable: String
    /// The `process_exited` message.
    public let processExited: String

    /// Creates the input strings.
    ///
    /// - Parameters:
    ///   - inputQueueFull: The `input_queue_full` message.
    ///   - surfaceUnavailable: The `surface_unavailable` message.
    ///   - processExited: The `process_exited` message.
    public init(
        inputQueueFull: String,
        surfaceUnavailable: String,
        processExited: String
    ) {
        self.inputQueueFull = inputQueueFull
        self.surfaceUnavailable = surfaceUnavailable
        self.processExited = processExited
    }

    /// The `inputQueueFull` message prefixed with the legacy `"ERROR: "` socket
    /// envelope.
    public var inputQueueFullSocketError: String { "ERROR: \(inputQueueFull)" }

    /// The `surfaceUnavailable` message prefixed with the legacy `"ERROR: "`
    /// socket envelope.
    public var surfaceUnavailableSocketError: String { "ERROR: \(surfaceUnavailable)" }

    /// The `processExited` message prefixed with the legacy `"ERROR: "` socket
    /// envelope.
    public var processExitedSocketError: String { "ERROR: \(processExited)" }
}

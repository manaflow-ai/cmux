public import Foundation

/// The app-bundle-resolved localized terminal-input error strings, shared by
/// terminal creation, `surface.send_text`, and `surface.send_key`.
///
/// Lifted from the legacy `TerminalController` static `terminal*Message`
/// computed properties (each a `String(localized:)`). They MUST resolve in the app
/// conformance (app bundle): inside the package `String(localized:)` binds to the
/// package bundle, which lacks the keys and silently drops the Japanese
/// translation (a wire change). The app resolves them and passes them through.
public struct ControlSurfaceInputStrings: Sendable, Equatable {
    /// `rpc.v2.terminalCreation.error.initialInputRequiresTerminalType` — the
    /// message used when creation input targets a non-terminal surface.
    public let initialInputRequiresTerminalType: String
    /// The `input_queue_full` message.
    public let inputQueueFull: String
    /// The `surface_unavailable` message.
    public let surfaceUnavailable: String
    /// The `process_exited` message.
    public let processExited: String

    /// Creates the input strings.
    ///
    /// - Parameters:
    ///   - initialInputRequiresTerminalType: The message used when creation input
    ///     targets a non-terminal surface.
    ///   - inputQueueFull: The `input_queue_full` message.
    ///   - surfaceUnavailable: The `surface_unavailable` message.
    ///   - processExited: The `process_exited` message.
    public init(
        initialInputRequiresTerminalType: String,
        inputQueueFull: String,
        surfaceUnavailable: String,
        processExited: String
    ) {
        self.initialInputRequiresTerminalType = initialInputRequiresTerminalType
        self.inputQueueFull = inputQueueFull
        self.surfaceUnavailable = surfaceUnavailable
        self.processExited = processExited
    }
}

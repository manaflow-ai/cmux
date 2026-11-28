#if DEBUG
public import Foundation

/// The result of one `debug.textbox.interact` action on a terminal panel's
/// text box.
public struct ControlDebugTextBoxInteraction: Sendable, Equatable {
    /// The terminal panel's surface id.
    public let surfaceID: UUID
    /// The free-form interaction state dictionary the text view reported
    /// (bridged from its Foundation form; JSON-safe by construction).
    public let state: JSONValue

    /// Creates an interaction result.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal panel's surface id.
    ///   - state: The interaction state payload.
    public init(surfaceID: UUID, state: JSONValue) {
        self.surfaceID = surfaceID
        self.state = state
    }
}
#endif

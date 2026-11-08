/// The terminal outcome of an asynchronous Web Inspector operation.
public enum ControlSimulatorWebInspectorCompletion: Sendable, Equatable {
    /// A target refresh completed with a new snapshot.
    case targets(ControlSimulatorWebInspectorSnapshot)
    /// An attach operation completed with a new session state.
    case session(ControlSimulatorWebInspectorSessionSnapshot)
    /// A highlight operation completed with the effective setting.
    case highlighted(Bool)
    /// The attached session was released.
    case released
    /// A protocol message returned a JSON response.
    case response(json: String, truncated: Bool)
    /// The operation failed with a stable code and user-safe message.
    case failed(code: String, message: String)
}

/// The terminal outcome of a native Simulator operation.
public enum ControlSimulatorOperationCompletion: Sendable, Equatable {
    /// The operation completed and returned a JSON payload.
    case success(JSONValue)
    /// The operation failed with a stable code and user-safe message.
    case failed(code: String, message: String)
}

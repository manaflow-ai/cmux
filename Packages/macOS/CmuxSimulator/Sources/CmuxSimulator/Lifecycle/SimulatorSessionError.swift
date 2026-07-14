/// Failure opening a simulator session.
public enum SimulatorSessionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// No device with the requested UDID exists in the local device set.
    case deviceNotFound(SimulatorDeviceUDID)
    /// The device exists but cannot host a session right now.
    case deviceNotOpenable(SimulatorOpenRefusalReason)

    public var description: String {
        switch self {
        case .deviceNotFound(let udid):
            return "No simulator device with UDID \(udid.rawValue) exists"
        case .deviceNotOpenable(.unavailable):
            return "The simulator device is unavailable (runtime not installed)"
        case .deviceNotOpenable(.transitioning(let state)):
            return "The simulator device is busy (\(state.displayName))"
        }
    }
}

/// The lifecycle decision for opening a session on a device.
public enum SimulatorOpenAction: Hashable, Sendable {
    /// Boot the device; the session owns its shutdown.
    case boot
    /// Attach to the already-booted device without touching its lifecycle.
    case attach
    /// Refuse to open the session.
    case refuse(SimulatorOpenRefusalReason)
}

/// Why a device cannot host a session right now.
public enum SimulatorOpenRefusalReason: Hashable, Sendable {
    /// The device's runtime is not installed or otherwise unusable.
    case unavailable
    /// The device is mid-transition (booting, shutting down, creating, or an
    /// unrecognized state); opening now would race a foreign lifecycle change.
    case transitioning(SimulatorDeviceState)
}

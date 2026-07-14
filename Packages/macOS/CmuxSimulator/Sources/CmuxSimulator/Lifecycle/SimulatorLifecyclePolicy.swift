/// The pure boot/attach/shutdown decision rules for simulator sessions.
///
/// Separated from ``SimulatorDeviceSession`` (which performs the effects) so
/// the isolation invariants are unit-testable without a process seam:
///
/// - A shutdown, available device is booted — cmux then owns the shutdown.
/// - An already-booted device is attached to — cmux never shuts it down.
/// - Anything mid-transition or unavailable is refused outright.
public struct SimulatorLifecyclePolicy: Sendable {
    /// Creates the default policy.
    public init() {}

    /// Decides how to open a session on a device.
    ///
    /// - Parameter device: The device's current catalog record.
    /// - Returns: The action to take.
    public func openAction(for device: SimulatorDevice) -> SimulatorOpenAction {
        guard device.isAvailable else { return .refuse(.unavailable) }
        switch device.state {
        case .booted:
            return .attach
        case .shutdown:
            return .boot
        case .booting, .shuttingDown, .creating, .unknown:
            return .refuse(.transitioning(device.state))
        }
    }

    /// Whether closing a session should shut the device down.
    ///
    /// - Parameter ownership: Who booted the device.
    /// - Returns: `true` only when cmux booted the device itself.
    public func shouldShutdownOnClose(ownership: SimulatorSessionOwnership) -> Bool {
        ownership == .bootedByCmux
    }
}

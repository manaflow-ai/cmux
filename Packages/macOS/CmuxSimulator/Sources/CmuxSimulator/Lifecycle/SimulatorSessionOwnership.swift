/// Who booted the simulator device a session is displaying.
///
/// Ownership decides teardown: cmux shuts a device down on pane close only
/// when cmux itself booted it. A device that was already running belongs to
/// whoever booted it, and cmux must never shut it down.
public enum SimulatorSessionOwnership: Hashable, Sendable {
    /// cmux booted the device for this session and owns its shutdown.
    case bootedByCmux
    /// The device was already booted by someone else; cmux only attached to
    /// display it and must leave it running on close.
    case attachedToRunningDevice
}

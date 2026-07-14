/// The lifecycle phase a simulator pane is in, projected for the UI.
public enum SimulatorPanePhase: Hashable, Sendable {
    /// The pane exists but has not started its session yet.
    case idle
    /// Resolving the `--device` query against the local device catalog.
    case resolvingDevice
    /// cmux is booting the (previously shut down) device.
    case booting
    /// Attaching to a device that was already booted.
    case attaching
    /// The session is open and frames are streaming.
    case streaming
    /// The session ended (pane closed or stream finished).
    case stopped
    /// The session failed.
    case failed(SimulatorPaneFailure)
}

/// Why a simulator pane's session failed.
public enum SimulatorPaneFailure: Hashable, Sendable {
    /// No device in the catalog matched the requested name or UDID.
    case deviceNotFound(query: String)
    /// The device exists but refused to open, or an underlying `simctl`
    /// invocation failed; carries a diagnostic description.
    case sessionFailed(detail: String)
}

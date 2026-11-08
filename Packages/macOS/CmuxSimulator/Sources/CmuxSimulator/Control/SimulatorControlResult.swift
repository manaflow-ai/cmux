/// The typed output of a ``SimulatorControlAction``.
public enum SimulatorControlResult: Equatable, Sendable {
    /// The action completed without a returned value.
    case none
    /// `simctl launch` returned an optional process identifier.
    case processIdentifier(Int32?)
    /// A clipboard or log action returned text.
    case text(String)
    /// Application discovery returned installed bundle metadata.
    case applications([SimulatorInstalledApplication])
    /// Permission readback returned effective authorization values.
    case privacy(SimulatorPrivacySnapshot)
    /// Camera readback returned source, mirror, injection, and device status.
    case cameraStatus(SimulatorCameraStatus)
    /// Interface readback returned live private accessibility values.
    case interfaceStatus(SimulatorInterfaceStatus)
    /// Accessibility inspection returned a bounded element tree.
    case accessibility(SimulatorAccessibilitySnapshot)
    /// Foreground-app inspection returned metadata, or no active app.
    case foregroundApplication(SimulatorApplicationInfo?)
    /// Web Inspector discovery returned live page targets.
    case webInspectorTargets([SimulatorWebInspectorTarget])
    /// A Web Inspector attach or release returned the current session state.
    case webInspectorSession(SimulatorWebInspectorSessionStatus)
    /// The caller must own and cancel this long-running process.
    case command(SimulatorCommandDescriptor)
}

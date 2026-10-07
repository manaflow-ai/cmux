/// A native action that the app can dispatch to an isolated Simulator worker.
public enum ControlSimulatorOperation: Sendable, Equatable {
    /// Reads the selected device and display identity for external tooling.
    case context
    /// Boots and attaches the selected device before returning its capture identity.
    case prepareScreenshot
    /// Selects and attaches a device in the resolved Simulator pane.
    case selectDevice(String)
    /// Restarts a failed or crash-fused Simulator worker for the selected device.
    case recover
    /// Sends an ordered sequence of normalized touch events.
    case gesture([ControlSimulatorTouch])
    /// Presses a named simulated hardware button.
    case hardwareButton(String)
    /// Rotates the simulated device to a named orientation.
    case rotate(String)
    /// Enables or disables one Core Animation diagnostic.
    case coreAnimation(diagnostic: String, enabled: Bool)
    /// Delivers a memory warning to the simulated device.
    case memoryWarning
    /// Reads up to the requested number of recent Simulator events.
    case eventLog(limit: Int)
    /// Shows, hides, or toggles the native Simulator tools inspector.
    case tools(String)
    /// Configures a camera source for an application or disables camera injection.
    case cameraConfigure(
        source: String,
        path: String?,
        loops: Bool,
        hostDeviceID: String?,
        bundleIdentifier: String?
    )
    /// Switches the active camera feed without changing the target application.
    case cameraSwitch(source: String, path: String?, loops: Bool, hostDeviceID: String?)
    /// Sets automatic, enabled, or disabled camera mirroring.
    case cameraMirror(String)
    /// Reads the current camera-injection status.
    case cameraStatus
    /// Reads the selected app's effective permission values.
    case permissionsRead(bundleIdentifier: String?)
    /// Grants, revokes, or resets one canonical permission service.
    case permissionsSet(action: String, service: String, bundleIdentifier: String)
    /// Reads every supported Simulator-wide interface setting.
    case interfaceStatus
    /// Sets one canonical Simulator-wide interface option.
    case interfaceSet(option: String, value: String)
    /// Reads a bounded accessibility tree from the isolated worker.
    case accessibility
    /// Reads metadata for the frontmost simulated application.
    case foregroundApplication

    /// Whether success changes state outside the requesting socket operation.
    public var commitsExternalMutation: Bool {
        switch self {
        case .context, .eventLog, .cameraStatus, .permissionsRead,
             .interfaceStatus, .accessibility, .foregroundApplication:
            false
        case .prepareScreenshot, .selectDevice, .recover, .gesture,
             .hardwareButton, .rotate,
             .coreAnimation, .memoryWarning, .tools, .cameraConfigure,
             .cameraSwitch, .cameraMirror, .permissionsSet, .interfaceSet:
            true
        }
    }
}

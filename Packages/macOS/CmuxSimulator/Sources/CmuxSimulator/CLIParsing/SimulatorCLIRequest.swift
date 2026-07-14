/// A parsed `cmux simulator …` invocation.
public enum SimulatorCLIRequest: Hashable, Sendable {
    /// Print the namespace usage.
    case help
    /// List available simulator devices.
    case list
    /// Open a simulator pane for a device.
    case open(SimulatorCLIOpenRequest)
    /// Close a simulator pane.
    case close(SimulatorCLICloseRequest)
}

/// The parsed arguments of `cmux simulator open`.
public struct SimulatorCLIOpenRequest: Hashable, Sendable {
    /// The required `--device` value: a device name or UDID.
    public let deviceQuery: String
    /// The raw `--workspace` handle, before socket-side normalization.
    public let workspace: String?
    /// The raw `--window` handle, before socket-side normalization.
    public let window: String?
    /// The `--focus` value; defaults to `false` so opening never steals focus.
    public let focus: Bool

    /// Creates an open request.
    ///
    /// - Parameters:
    ///   - deviceQuery: The device name or UDID.
    ///   - workspace: The raw `--workspace` handle, if given.
    ///   - window: The raw `--window` handle, if given.
    ///   - focus: Whether the new pane may take focus. Defaults to `false`.
    public init(deviceQuery: String, workspace: String? = nil, window: String? = nil, focus: Bool = false) {
        self.deviceQuery = deviceQuery
        self.workspace = workspace
        self.window = window
        self.focus = focus
    }
}

/// The parsed arguments of `cmux simulator close`.
public struct SimulatorCLICloseRequest: Hashable, Sendable {
    /// The raw `--surface` handle of the pane to close, if given.
    public let surface: String?
    /// The raw `--workspace` handle, before socket-side normalization.
    public let workspace: String?
    /// The raw `--window` handle, before socket-side normalization.
    public let window: String?

    /// Creates a close request.
    ///
    /// - Parameters:
    ///   - surface: The raw `--surface` handle, if given.
    ///   - workspace: The raw `--workspace` handle, if given.
    ///   - window: The raw `--window` handle, if given.
    public init(surface: String? = nil, workspace: String? = nil, window: String? = nil) {
        self.surface = surface
        self.workspace = workspace
        self.window = window
    }
}

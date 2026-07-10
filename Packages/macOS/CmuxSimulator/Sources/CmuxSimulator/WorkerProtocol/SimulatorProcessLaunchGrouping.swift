/// Selects the process-group boundary for a Simulator subprocess.
package enum SimulatorProcessLaunchGrouping: Sendable {
    /// Starts a group owned by the subprocess so its complete command tree can be signalled.
    case dedicatedProcessGroup

    /// Keeps the subprocess in its caller's group and limits command-local signals to its PID.
    case inheritedProcessGroup
}

/// Options projected onto `simctl launch`.
public struct SimulatorLaunchConfiguration: Equatable, Sendable {
    /// Arguments passed to the application after its bundle identifier.
    public let arguments: [String]
    /// Environment variables exported with the `SIMCTL_CHILD_` prefix.
    public let environment: [String: String]
    /// Terminates an existing instance before launching.
    public let terminateRunningProcess: Bool
    /// Starts the process suspended for a debugger.
    public let waitForDebugger: Bool

    /// Creates launch options.
    /// - Parameters:
    ///   - arguments: Application arguments.
    ///   - environment: Application environment variables.
    ///   - terminateRunningProcess: Whether to replace an existing process.
    ///   - waitForDebugger: Whether to suspend at startup.
    public init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        terminateRunningProcess: Bool = false,
        waitForDebugger: Bool = false
    ) {
        self.arguments = arguments
        self.environment = environment
        self.terminateRunningProcess = terminateRunningProcess
        self.waitForDebugger = waitForDebugger
    }
}

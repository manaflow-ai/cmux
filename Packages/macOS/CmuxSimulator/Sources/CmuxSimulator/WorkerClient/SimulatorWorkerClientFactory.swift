import Foundation

/// Constructs worker clients around an injected host executable.
public struct SimulatorWorkerClientFactory: Sendable {
    private let executableURL: URL

    /// Creates a factory, defaulting to the current app executable.
    /// - Parameter executableURL: Executable re-launched in isolated worker mode.
    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// Creates a client that re-executes the factory's host binary.
    /// - Parameters:
    ///   - ackTimeout: Ordered ping deadline before treating the child as hung.
    ///   - simulatorControl: Injected public Simulator control service.
    public func makeClient(
        ackTimeout: Duration = .seconds(3),
        simulatorControl: any SimulatorControlling = SimulatorControlService()
    ) -> SimulatorWorkerClient {
        SimulatorWorkerClient(
            executableURL: executableURL,
            ackTimeout: ackTimeout,
            simulatorControl: simulatorControl
        )
    }
}

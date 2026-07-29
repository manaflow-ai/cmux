internal import Foundation

/// Production launcher for a standalone SSH reverse-relay transport.
public struct RemoteReverseRelayLauncher: RemoteReverseRelayLaunching {
    private static let startupGracePeriod: TimeInterval = 0.5

    /// Creates a production reverse-relay launcher.
    public init() {}

    /// Launches `/usr/bin/ssh` with null stdin/stdout and captured stderr.
    public func launch(
        arguments: [String],
        environment: [String: String]?,
        startupHandler: @escaping @Sendable (
            any RemoteReverseRelayProcess
        ) -> Void,
        terminationHandler: @escaping @Sendable (
            any RemoteReverseRelayProcess,
            String?
        ) -> Void
    ) throws -> any RemoteReverseRelayProcess {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe
        )
        try process.run()
        relayProcess.captureTermination { [weak relayProcess] detail in
            guard let relayProcess else { return }
            terminationHandler(relayProcess, detail)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.startupGracePeriod
        ) { [weak relayProcess] in
            guard let relayProcess, relayProcess.isRunning else { return }
            startupHandler(relayProcess)
        }
        return relayProcess
    }
}

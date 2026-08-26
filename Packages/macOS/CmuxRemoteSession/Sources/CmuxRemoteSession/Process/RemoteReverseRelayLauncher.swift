internal import Foundation

/// Production launcher for a standalone SSH reverse-relay transport.
public struct RemoteReverseRelayLauncher: RemoteReverseRelayLaunching {
    private static let startupTimeout: TimeInterval = 10

    /// Creates a production reverse-relay launcher.
    public init() {}

    /// Launches `/usr/bin/ssh` with null stdin/stdout and captured stderr.
    public func launch(
        arguments: [String],
        environment: [String: String]?,
        startupMarker: String,
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
        relayProcess.captureLifecycle(
            startupMarker: startupMarker,
            startupTimeout: Self.startupTimeout,
            startupHandler: { [weak relayProcess] in
                guard let relayProcess else { return }
                startupHandler(relayProcess)
            },
            terminationHandler: { [weak relayProcess] detail in
                guard let relayProcess else { return }
                terminationHandler(relayProcess, detail)
            }
        )
        return relayProcess
    }
}

internal import Foundation

/// Production launcher for a standalone SSH reverse-relay transport.
public struct RemoteReverseRelayLauncher: RemoteReverseRelayLaunching {
    /// Creates a production reverse-relay launcher.
    public init() {}

    /// Launches `/usr/bin/ssh` with null stdin/stdout and captured stderr.
    public func launch(
        arguments: [String],
        environment: [String: String]?,
        terminationHandler: @escaping @Sendable (any RemoteReverseRelayProcess) -> Void
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
        process.terminationHandler = { [weak relayProcess] _ in
            guard let relayProcess else { return }
            terminationHandler(relayProcess)
        }
        try process.run()
        return relayProcess
    }
}

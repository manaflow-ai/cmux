internal import CmuxTerminalRendererRuntime
internal import CmuxTerminalRendererControl
internal import Darwin
internal import Foundation
internal import OSLog

nonisolated private let executableLogger = Logger(
    subsystem: "com.cmuxterm.cmux-terminal-renderer",
    category: "worker"
)

@main
struct RendererWorkerExecutable {
    static func main() async {
        let exitCode: Int32
        do {
            let launch = try RendererWorkerLaunchConfiguration(
                arguments: Array(CommandLine.arguments.dropFirst()),
                environment: ProcessInfo.processInfo.environment
            )
            let processID = getpid()
            guard processID > 0 else {
                throw RendererControlChannelError.invalidDescriptor(processID)
            }
            let ready = try RendererWorkerReady(
                processID: UInt32(processID),
                effectiveUserID: geteuid(),
                sceneCapabilities: .allKnown
            )
            let factory = try GhosttyPresentationEngineFactory()
            let runtime = RendererWorkerRuntime(
                expectation: launch.expectation,
                ready: ready,
                engineFactory: factory
            )
            let channel = try RendererControlChannel(
                descriptor: launch.controlDescriptor
            )
            exitCode = await run(runtime: runtime, channel: channel)
            await runtime.terminate()
            channel.close()
        } catch let error as RendererWorkerLaunchConfigurationError {
            executableLogger.error("invalid launch configuration: \(String(describing: error), privacy: .public)")
            exitCode = EX_USAGE
        } catch {
            executableLogger.fault("worker initialization failed: \(String(describing: error), privacy: .public)")
            exitCode = EX_SOFTWARE
        }
        Darwin.exit(exitCode)
    }

    private static func run(
        runtime: RendererWorkerRuntime,
        channel: RendererControlChannel
    ) async -> Int32 {
        var decoder = RendererControlIncrementalDecoder(
            expectedDirection: .daemonToWorker
        )
        var encoder = RendererControlEncoder(direction: .workerToDaemon)
        do {
            while true {
                let bytes = try await channel.readChunk()
                if bytes.isEmpty {
                    try decoder.finish()
                    return EX_OK
                }
                for envelope in try decoder.feed(bytes) {
                    let result = await runtime.handle(envelope.message)
                    var sentFatal = false
                    for reply in result.replies {
                        if case .fatal = reply { sentFatal = true }
                        try await channel.write(try encoder.encode(reply))
                    }
                    if result.shouldExit {
                        return sentFatal ? EX_SOFTWARE : EX_OK
                    }
                }
            }
        } catch {
            executableLogger.error("control channel failed: \(String(describing: error), privacy: .public)")
            let diagnostic = boundedDiagnostic(String(describing: error))
            if let fatal = try? RendererFatal(
                code: .protocolViolation,
                diagnostic: diagnostic
            ), let encoded = try? encoder.encode(.fatal(fatal)) {
                try? await channel.write(encoded)
            }
            return EX_IOERR
        }
    }

    private static func boundedDiagnostic(_ value: String) -> String {
        let maximum = RendererControlProtocol.maximumDiagnosticLength
        guard value.utf8.count > maximum else { return value }
        var result = value
        while result.utf8.count > maximum {
            result.removeLast()
        }
        return result
    }
}

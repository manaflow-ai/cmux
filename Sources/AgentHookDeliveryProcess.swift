import Darwin
import Foundation
import OSLog

nonisolated private let agentHookDeliveryProcessLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentHookDelivery"
)

/// Runs one admitted hook through the bundled CLI with a cancellable deadline.
nonisolated struct AgentHookDeliveryProcess: Sendable {
    private enum Completion: Sendable {
        case exited(Int32)
        case deadline
        case cancelled
    }

    private let executableURLProvider: @Sendable () -> URL?
    private let processTimeout: Duration
    private let terminationGrace: Duration

    init(
        executableURLProvider: @escaping @Sendable () -> URL? = {
            Bundle.main.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false)
        },
        processTimeout: Duration = .seconds(15),
        terminationGrace: Duration = .milliseconds(250)
    ) {
        self.executableURLProvider = executableURLProvider
        self.processTimeout = processTimeout
        self.terminationGrace = terminationGrace
    }

    func deliver(_ event: AgentHookDeliveryEvent) async {
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            agentHookDeliveryProcessLogger.error("Bundled hook-delivery CLI is unavailable")
            return
        }

        let input: FileHandle
        do {
            input = try Self.makeAnonymousInputFile(payload: Data(event.payload.utf8))
        } catch {
            agentHookDeliveryProcessLogger.error(
                "Could not stage hook input: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        defer { try? input.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--socket", event.socketPath] + event.deliveryArguments
        process.environment = deliveryEnvironment(event: event, executableURL: executableURL)
        if !event.relayBacked,
           let workingDirectory = event.environment["PWD"],
           FileManager.default.fileExists(atPath: workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let terminations = AsyncStream<Int32>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.yield(terminatedProcess.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
            // The CLI repeats this in its first instructions. This parent-side
            // attempt closes the spawn window before the child reaches main().
            _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            process.terminationHandler = nil
            agentHookDeliveryProcessLogger.error(
                "Could not launch hook delivery: \(error.localizedDescription, privacy: .private)"
            )
            return
        }

        let completion = await awaitCompletion(
            terminations: terminations,
            processID: process.processIdentifier
        )
        process.terminationHandler = nil
        switch completion {
        case .exited(0):
            return
        case .exited(let status):
            agentHookDeliveryProcessLogger.error("Hook delivery exited with status \(status)")
        case .deadline:
            agentHookDeliveryProcessLogger.error("Hook delivery exceeded its process deadline")
        case .cancelled:
            Self.terminateProcessGroup(processID: process.processIdentifier, signal: SIGKILL)
        }
    }

    func deliveryEnvironment(
        event: AgentHookDeliveryEvent,
        executableURL: URL
    ) -> [String: String] {
        let ambientEnvironment = ProcessInfo.processInfo.environment
        let ambientKeys = [
            "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER",
            "CMUX_BUNDLE_ID", "CMUX_CLI_SENTRY_DISABLED", "CMUX_SOCKET_PASSWORD", "CMUX_TAG",
        ]
        var environment: [String: String] = [:]
        for key in ambientKeys {
            environment[key] = ambientEnvironment[key]
        }
        let deliveredEventEnvironment: [String: String]
        if event.relayBacked {
            // Remote paths, launch argv, proxy configuration, and PIDs describe
            // the remote host. Replaying them through the local Mac CLI can
            // probe an unrelated local process, write a same-named local path,
            // or persist an unlaunchable local resume command. Preserve only
            // routing that the relay has alias-rewritten plus explicit
            // notification/subagent policy bits.
            let relayDeliveryKeys: Set<String> = [
                "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
                "CMUX_AGENT_MANAGED_SUBAGENT",
                "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
                "CMUX_SURFACE_ID",
                "CMUX_WORKSPACE_ID",
            ]
            deliveredEventEnvironment = event.environment.filter { relayDeliveryKeys.contains($0.key) }
        } else {
            deliveredEventEnvironment = event.environment
        }
        environment.merge(deliveredEventEnvironment, uniquingKeysWith: { _, eventValue in eventValue })
        environment["CMUX_SOCKET_PATH"] = event.socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = executableURL.path
        environment["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] = "1"
        if event.relayBacked {
            environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] = "1"
        } else {
            environment.removeValue(forKey: "CMUX_AGENT_HOOK_RELAY_ORIGIN")
        }
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "12"
        return environment
    }

    private func awaitCompletion(
        terminations: AsyncStream<Int32>,
        processID: pid_t
    ) async -> Completion {
        await withTaskGroup(of: Completion.self) { group in
            group.addTask {
                for await status in terminations {
                    return .exited(status)
                }
                return .cancelled
            }
            let processTimeout = processTimeout
            let terminationGrace = terminationGrace
            group.addTask {
                do {
                    // This is the child lifetime deadline, not polling or settling.
                    try await ContinuousClock().sleep(for: processTimeout)
                } catch {
                    return .cancelled
                }
                Self.terminateProcessGroup(processID: processID, signal: SIGTERM)
                do {
                    // A bounded grace period precedes process-group SIGKILL.
                    try await ContinuousClock().sleep(for: terminationGrace)
                } catch {
                    return .cancelled
                }
                Self.terminateProcessGroup(processID: processID, signal: SIGKILL)
                return .deadline
            }
            let completion = await group.next() ?? .cancelled
            group.cancelAll()
            return completion
        }
    }

    private static func terminateProcessGroup(processID: pid_t, signal: Int32) {
        if Darwin.getpgid(processID) == processID {
            _ = Darwin.kill(-processID, signal)
        } else {
            _ = Darwin.kill(processID, signal)
        }
    }

    private static func makeAnonymousInputFile(payload: Data) throws -> FileHandle {
        var template = Array("\(NSTemporaryDirectory())cmux-agent-hook.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.mkstemp(baseAddress)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let path = template.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        _ = Darwin.unlink(path)
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)

        do {
            try payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard let baseAddress = bytes.baseAddress else { break }
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
            guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

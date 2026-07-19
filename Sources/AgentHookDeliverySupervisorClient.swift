import CmuxFoundation
import Darwin
import Foundation

/// Launches one hook delivery beneath the bundled process-group supervisor.
///
/// The live supervisor process and its open control lease are the delivery
/// identity. Swift never signals a process-group number, so a recycled PID
/// cannot redirect cancellation to an unrelated process.
final class AgentHookDeliverySupervisorClient: @unchecked Sendable {
    enum DirectResult: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
        case cancelled
        case launchError(Int32)
        case transportError(String)
    }

    struct Launch: Sendable {
        let directResult: DirectResult
        let handle: Handle
    }

    final class Handle: @unchecked Sendable {
        let id = UUID()

        private let controlLock = NSLock()
        private var controlWriter: FileHandle?
        private let process: Process
        private let terminationTask: Task<Int32, Never>

        fileprivate init(
            controlWriter: FileHandle,
            process: Process,
            terminationTask: Task<Int32, Never>
        ) {
            self.controlWriter = controlWriter
            self.process = process
            self.terminationTask = terminationTask
        }

        /// Closing the lease is the only app-side cancellation operation.
        /// The supervisor observes EOF and signals its own still-live group.
        func requestCancellation() {
            let writer: FileHandle?
            controlLock.lock()
            writer = controlWriter
            controlWriter = nil
            controlLock.unlock()
            try? writer?.close()
        }

        /// Waits until the supervisor has released the global delivery permit.
        func waitForTermination() async -> Int32 {
            let status = await withTaskCancellationHandler {
                await terminationTask.value
            } onCancel: {
                requestCancellation()
            }
            process.terminationHandler = nil
            requestCancellation()
            return status
        }

        deinit {
            requestCancellation()
        }
    }

    private static let maximumProtocolBytes = 1_024
    private static let protocolPrefix = "CMUX-HOOK-SUPERVISOR"

    static func launch(
        supervisorURL: URL,
        childURL: URL,
        childArguments: [String],
        environment: [String: String],
        payload: Data,
        errorOutput: FileHandle,
        directTimeout: TimeInterval,
        groupTimeout: TimeInterval,
        terminationGrace: TimeInterval
    ) async throws -> Launch {
        let controlPipe = Pipe()
        let statusPipe = Pipe()
        let pipeHandles = [
            controlPipe.fileHandleForReading,
            controlPipe.fileHandleForWriting,
            statusPipe.fileHandleForReading,
            statusPipe.fileHandleForWriting,
        ]
        do {
            try configureCloseOnExec(pipeHandles)
        } catch {
            for handle in pipeHandles {
                try? handle.close()
            }
            throw error
        }
        let process = Process()
        process.executableURL = supervisorURL
        process.arguments = [
            "--payload-bytes", String(payload.count),
            "--direct-timeout-ms", timeoutMilliseconds(directTimeout),
            "--group-timeout-ms", timeoutMilliseconds(groupTimeout),
            "--termination-grace-ms", timeoutMilliseconds(terminationGrace),
            "--", childURL.path,
        ] + childArguments
        process.environment = environment
        process.standardInput = controlPipe
        process.standardOutput = statusPipe
        process.standardError = errorOutput

        let terminationChannel = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        process.terminationHandler = { terminatedProcess in
            terminationChannel.continuation.yield(terminatedProcess.terminationStatus)
            terminationChannel.continuation.finish()
        }
        let terminationTask = Task.detached {
            for await status in terminationChannel.stream {
                return status
            }
            return -1
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationChannel.continuation.finish()
            try? controlPipe.fileHandleForReading.close()
            try? controlPipe.fileHandleForWriting.close()
            try? statusPipe.fileHandleForReading.close()
            try? statusPipe.fileHandleForWriting.close()
            throw error
        }

        // The spawned supervisor owns the duplicated child-side descriptors.
        // Closing these parent copies makes status EOF and control-lease EOF
        // reflect the two actual owners rather than the Pipe containers.
        try? controlPipe.fileHandleForReading.close()
        try? statusPipe.fileHandleForWriting.close()
        let handle = Handle(
            controlWriter: controlPipe.fileHandleForWriting,
            process: process,
            terminationTask: terminationTask
        )
        let supervisorPID = process.processIdentifier

        return await withTaskCancellationHandler {
            do {
                try await Task.detached {
                    try controlPipe.fileHandleForWriting.writeProcessPipeInput(payload)
                }.value
            } catch {
                let payloadWriteError = error
                handle.requestCancellation()
                do {
                    let protocolData = try await Task.detached {
                        try readProtocol(from: statusPipe.fileHandleForReading)
                    }.value
                    let result = parseProtocol(protocolData, supervisorPID: supervisorPID)
                    if case .transportError = result {
                        return Launch(
                            directResult: .transportError(
                                "Writing the supervisor payload failed: "
                                    + "\(payloadWriteError.localizedDescription)"
                            ),
                            handle: handle
                        )
                    }
                    return Launch(directResult: result, handle: handle)
                } catch {
                    return Launch(
                        directResult: .transportError(
                            "Writing the supervisor payload failed: "
                                + "\(payloadWriteError.localizedDescription)"
                        ),
                        handle: handle
                    )
                }
            }

            do {
                let protocolData = try await Task.detached {
                    try readProtocol(from: statusPipe.fileHandleForReading)
                }.value
                let result = parseProtocol(protocolData, supervisorPID: supervisorPID)
                if case .transportError = result {
                    handle.requestCancellation()
                }
                return Launch(directResult: result, handle: handle)
            } catch {
                handle.requestCancellation()
                return Launch(
                    directResult: .transportError(
                        "Reading the supervisor result failed: \(error.localizedDescription)"
                    ),
                    handle: handle
                )
            }
        } onCancel: {
            handle.requestCancellation()
        }
    }

    private static func timeoutMilliseconds(_ timeout: TimeInterval) -> String {
        guard timeout.isFinite else { return "86400000" }
        let milliseconds = min(86_400_000, max(1, (timeout * 1_000).rounded(.up)))
        return String(Int64(milliseconds))
    }

    private static func configureCloseOnExec(_ handles: [FileHandle]) throws {
        for handle in handles {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func readProtocol(from handle: FileHandle) throws -> Data {
        defer { try? handle.close() }
        var protocolData = Data()
        while let chunk = try handle.read(upToCount: 256), !chunk.isEmpty {
            guard protocolData.count <= maximumProtocolBytes - chunk.count else {
                throw CocoaError(.fileReadTooLarge)
            }
            protocolData.append(chunk)
        }
        return protocolData
    }

    private static func parseProtocol(
        _ data: Data,
        supervisorPID: pid_t
    ) -> DirectResult {
        guard data.last == UInt8(ascii: "\n"),
              let text = String(data: data, encoding: .utf8),
              text.last == "\n" else {
            return .transportError("Supervisor result was not a newline-terminated UTF-8 frame.")
        }
        let framedText = text.dropLast()
        guard !framedText.isEmpty else {
            return .transportError("Supervisor returned an empty protocol.")
        }
        let lines = framedText.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 1 || lines.count == 2 else {
            return .transportError("Supervisor returned an invalid frame count.")
        }

        let resultLine: Substring
        if lines.count == 2 {
            let ready = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard ready.count == 5,
                  ready[0] == Substring(protocolPrefix),
                  ready[1] == "1",
                  ready[2] == "READY",
                  Int32(ready[3]) == supervisorPID,
                  let childPID = Int32(ready[4]),
                  childPID > 1 else {
                return .transportError("Supervisor returned an invalid READY frame.")
            }
            resultLine = lines[1]
        } else {
            resultLine = lines[0]
        }

        let result = resultLine.split(separator: " ", omittingEmptySubsequences: false)
        guard result.count == 5,
              result[0] == Substring(protocolPrefix),
              result[1] == "1",
              result[2] == "RESULT",
              let value = Int32(result[4]) else {
            return .transportError("Supervisor returned an invalid RESULT frame.")
        }
        switch result[3] {
        case "EXIT":
            guard lines.count == 2, (0...255).contains(value) else {
                return .transportError("Supervisor EXIT result did not follow READY.")
            }
            return .exited(value)
        case "SIGNAL":
            guard lines.count == 2, value > 0, value < NSIG else {
                return .transportError("Supervisor SIGNAL result did not follow READY.")
            }
            return .signaled(value)
        case "TIMEOUT":
            guard value == 0 else {
                return .transportError("Supervisor returned an invalid timeout result.")
            }
            return .timedOut
        case "CANCELLED":
            guard value == 0 else {
                return .transportError("Supervisor returned an invalid cancellation result.")
            }
            return .cancelled
        case "LAUNCH_ERROR":
            guard value > 0 else {
                return .transportError("Supervisor returned an invalid launch error.")
            }
            return .launchError(value)
        default:
            return .transportError("Supervisor returned an unknown result kind.")
        }
    }
}

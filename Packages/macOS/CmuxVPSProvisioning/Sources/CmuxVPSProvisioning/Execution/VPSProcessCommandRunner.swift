internal import Darwin
public import Foundation

/// Production ``VPSCommandRunning``: spawns the process, drains stdout/stderr
/// concurrently, and enforces the timeout with terminate-then-SIGKILL
/// escalation.
///
/// Stateless; each `run` call owns its process-local state, so the struct is
/// trivially `Sendable`.
public struct VPSProcessCommandRunner: VPSCommandRunning {
    /// Creates the production runner.
    public init() {}

    /// Runs the process; see ``VPSCommandRunning/run(executable:arguments:environment:timeout:)``.
    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> VPSCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Duplicate the read descriptors while the handles are guaranteed
        // open; the detached drain tasks own (and close) the duplicates, so
        // handle teardown can never cross-wire a recycled fd.
        let stdoutDescriptor = try Self.duplicateDescriptor(stdoutPipe.fileHandleForReading.fileDescriptor)
        let stderrDescriptor: Int32
        do {
            stderrDescriptor = try Self.duplicateDescriptor(stderrPipe.fileHandleForReading.fileDescriptor)
        } catch {
            _ = Darwin.close(stdoutDescriptor)
            throw error
        }

        let (exitEvents, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            _ = Darwin.close(stdoutDescriptor)
            _ = Darwin.close(stderrDescriptor)
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            exitContinuation.finish()
            throw VPSProvisioningError.remoteCommandFailed(
                step: "launch \(URL(fileURLWithPath: executable).lastPathComponent)",
                detail: error.localizedDescription
            )
        }
        // Close the parent's copies of the pipe ends so the drains see EOF
        // as soon as the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Detached because the reads block; an Int32 fd is Sendable where a
        // FileHandle is not.
        let stdoutTask = Task.detached(priority: .utility) { Self.drainToEnd(fileDescriptor: stdoutDescriptor) }
        let stderrTask = Task.detached(priority: .utility) { Self.drainToEnd(fileDescriptor: stderrDescriptor) }

        var status: Int32?
        do {
            status = try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    for await exitStatus in exitEvents {
                        return exitStatus
                    }
                    return nil
                }
                group.addTask {
                    // Bounded, cancellable deadline: the timeout is the intended
                    // behavior of this API, cancelled when the exit wins the race.
                    try await Task.sleep(for: .seconds(max(0, timeout)))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let exitStatus = first else {
                    return nil
                }
                return exitStatus
            }
        } catch {
            // Surrounding-task cancellation: stop the child before rethrowing.
            Self.terminateThenKill(process)
            _ = await stdoutTask.value
            _ = await stderrTask.value
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw error
        }

        guard let exitStatus = status else {
            Self.terminateThenKill(process)
            _ = await stdoutTask.value
            _ = await stderrTask.value
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw VPSProvisioningError.remoteCommandFailed(
                step: URL(fileURLWithPath: executable).lastPathComponent,
                detail: "timed out after \(Int(timeout))s"
            )
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        return VPSCommandResult(
            status: exitStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func duplicateDescriptor(_ fileDescriptor: Int32) throws -> Int32 {
        let duplicate = Darwin.dup(fileDescriptor)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return duplicate
    }

    private static func drainToEnd(fileDescriptor: Int32) -> Data {
        defer { _ = Darwin.close(fileDescriptor) }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fileDescriptor, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == -1, errno == EINTR {
                continue
            }
            return collected
        }
    }

    private static func terminateThenKill(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached(priority: .utility) {
            // Bounded SIGKILL escalation deadline — an intended delay, not a
            // poll; the drain tasks' EOF (child death) gates result assembly.
            try? await Task.sleep(for: .seconds(2))
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

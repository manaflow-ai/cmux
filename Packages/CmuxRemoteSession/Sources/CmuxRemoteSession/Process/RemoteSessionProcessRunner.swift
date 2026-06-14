internal import CmuxFoundation
internal import Darwin
public import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

/// Production ``RemoteSessionProcessRunning``: spawns the process, captures
/// stdout/stderr on background readers, enforces the timeout with
/// terminate-then-SIGKILL escalation, and honors transfer cancellation.
///
/// Faithful lift of the legacy `WorkspaceRemoteSessionController.runProcess`
/// (minus the static test-override seam, which injection replaces): launch
/// and timeout NSError domain/codes/messages, the capture/close ordering,
/// stdin handling, and the debug-log lines are all pinned behavior.
///
/// Isolation: the struct is stateless (one immutable test hook); each `run`
/// call owns its process-local state. The capture readers run on the global
/// utility pool and hand their results through a small queue-confined box,
/// synchronized by the capture `DispatchGroup` before any read-back, exactly
/// like the legacy local-variable captures.
public struct RemoteSessionProcessRunner: RemoteSessionProcessRunning {
    /// Test observation seam (package tests only): invoked right after the
    /// stdout/stderr capture readers are installed, with the pipe read
    /// handles. The capture-survives-teardown regression test closes them to
    /// prove `run` still completes; production constructs the runner without
    /// a hook.
    let readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Void)?

    /// Creates the production runner.
    public init() {
        self.readHandlesDidInstall = nil
    }

    init(readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Void)?) {
        self.readHandlesDidInstall = readHandlesDidInstall
    }

    // Mutable capture-state shared between the two background pipe readers
    // and the blocking caller. Writes are confined to the serial
    // `captureQueue`; the caller only reads after `captureGroup.wait()`
    // ordered every writer before it. `@unchecked Sendable` because the
    // compiler cannot see that confinement (the legacy code expressed the
    // same contract with captured local `var`s).
    private final class PipeCaptureState: @unchecked Sendable {
        var stdoutData = Data()
        var stderrData = Data()
        var stdoutReadError: Error?
        var stderrReadError: Error?
    }

    /// Runs the request to completion on the calling thread; see
    /// ``RemoteSessionProcessRunning/run(_:operation:)``.
    public func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let executable = request.executable
        let arguments = request.arguments
        let timeout = request.timeout
        let stdin = request.stdin

        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment = request.environment {
            process.environment = environment
        }
        if let currentDirectory = request.currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "cmux.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        let captureState = PipeCaptureState()
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        // Snapshot independent descriptors on the calling thread, while the
        // handles are guaranteed open, and drain those duplicates. The contract
        // (pinned by the capture-survives-teardown test) is that closing the
        // read handles mid-run must not break the run. A closed FileHandle's
        // original descriptor can be recycled under a background reader; a
        // duplicated descriptor stays owned by the reader until it closes it.
        let stdoutDescriptor = dup(stdoutHandle.fileDescriptor)
        let stderrDescriptor = dup(stderrHandle.fileDescriptor)
        let duplicateDescriptorErrno = errno
        guard stdoutDescriptor >= 0, stderrDescriptor >= 0 else {
            if stdoutDescriptor >= 0 {
                _ = Darwin.close(stdoutDescriptor)
            }
            if stderrDescriptor >= 0 {
                _ = Darwin.close(stderrDescriptor)
            }
            try? stdoutHandle.close()
            try? stderrHandle.close()
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            let reason = String(cString: strerror(duplicateDescriptorErrno))
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to prepare process pipes for \(executableName): \(reason)",
            ])
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                _ = Darwin.close(stdoutDescriptor)
                captureGroup.leave()
            }
            let result = ProcessPipeEndRead.reading(fileDescriptor: stdoutDescriptor)
            captureQueue.sync {
                captureState.stdoutData = result.data
                captureState.stdoutReadError = result.readError
            }
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                _ = Darwin.close(stderrDescriptor)
                captureGroup.leave()
            }
            let result = ProcessPipeEndRead.reading(fileDescriptor: stderrDescriptor)
            captureQueue.sync {
                captureState.stderrData = result.data
                captureState.stderrReadError = result.readError
            }
        }
        readHandlesDidInstall?(stdoutHandle, stderrHandle)

        var didFinishCapture = false
        func finishCaptureAndCloseReadHandles() {
            guard !didFinishCapture else { return }
            didFinishCapture = true
            captureGroup.wait()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if let stdoutReadError = captureState.stdoutReadError {
                debugLog(
                    "remote.proc.stdoutReadError exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                    "error=\(stdoutReadError.localizedDescription)"
                )
            }
            if let stderrReadError = captureState.stderrReadError {
                debugLog(
                    "remote.proc.stderrReadError exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                    "error=\(stderrReadError.localizedDescription)"
                )
            }
        }

        do {
            try operation?.throwIfCancelled()
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            finishCaptureAndCloseReadHandles()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            if let operation, operation.isCancelled {
                terminateProcessAndWait()
                finishCaptureAndCloseReadHandles()
                throw operation.cancellationError
            }
            terminateProcessAndWait()
            finishCaptureAndCloseReadHandles()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        finishCaptureAndCloseReadHandles()
        let stdout = String(data: captureState.stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: captureState.stderrData, encoding: .utf8) ?? ""
        if let operation, operation.isCancelled {
            throw operation.cancellationError
        }
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(stdout.debugLogSnippet()) " +
            "stderr=\(stderr.debugLogSnippet())"
        )
        return RemoteCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(\.shellSingleQuoted)
            .joined(separator: " ")
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        CMUXDebugLog.logDebugEvent(message())
#endif
    }
}

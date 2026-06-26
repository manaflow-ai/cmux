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
    /// handles. Return `true` when the hook closes both handles, so the
    /// runner will not close already-closed `FileHandle` instances again.
    /// The capture-survives-teardown regression test uses that to prove
    /// `run` still completes; production constructs the runner without a hook.
    let readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Bool)?

    /// Creates the production runner.
    public init() {
        self.readHandlesDidInstall = nil
    }

    init(readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Bool)?) {
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
        var stdoutReadError: (any Error)?
        var stderrReadError: (any Error)?
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
        // Duplicate the descriptors on the calling thread, while the handles
        // are guaranteed open, and drain the duplicates. The contract (pinned
        // by the capture-survives-teardown test) is that closing the read
        // handles mid-run must not break or cross-wire capture: a closed
        // FileHandle's fd number can be recycled by another process, but the
        // duplicated fd remains attached to this pipe until the reader closes it.
        let stdoutDescriptor = try duplicateReadDescriptor(stdoutHandle.fileDescriptor)
        let stderrDescriptor: Int32
        do {
            stderrDescriptor = try duplicateReadDescriptor(stderrHandle.fileDescriptor)
        } catch {
            _ = Darwin.close(stdoutDescriptor)
            throw error
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { captureGroup.leave() }
            defer { _ = Darwin.close(stdoutDescriptor) }
            let result = ProcessPipeEndRead.reading(fileDescriptor: stdoutDescriptor)
            captureQueue.sync {
                captureState.stdoutData = result.data
                captureState.stdoutReadError = result.readError
            }
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { captureGroup.leave() }
            defer { _ = Darwin.close(stderrDescriptor) }
            let result = ProcessPipeEndRead.reading(fileDescriptor: stderrDescriptor)
            captureQueue.sync {
                captureState.stderrData = result.data
                captureState.stderrReadError = result.readError
            }
        }
        let readHandlesClosedByInstallHook = readHandlesDidInstall?(stdoutHandle, stderrHandle) ?? false

        var didFinishCapture = false
        func finishCaptureAndCloseReadHandles() {
            guard !didFinishCapture else { return }
            didFinishCapture = true
            captureGroup.wait()
            if !readHandlesClosedByInstallHook {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }
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
            // Stream stdin on a background thread so the timeout/termination
            // path below stays authoritative for slow or stalled transfers:
            // if the deadline fires we terminate the process, the child's read
            // end closes, and this writer unblocks. The fd is duped so the
            // writer owns its lifetime; SIGPIPE is suppressed and short writes
            // are looped so a remote that closes the channel early (e.g. a
            // failed redirect target) surfaces as a nonzero exit status rather
            // than crashing the app. This matters now that the cmuxd-remote
            // bootstrap streams the (multi-MB) daemon binary through ssh stdin
            // instead of scp (issue #6207); the legacy synchronous
            // `FileHandle.write` was safe only for the tiny stdin payloads in
            // use before.
            let writeHandle = pipe.fileHandleForWriting
            let writeDescriptor = Darwin.dup(writeHandle.fileDescriptor)
            if writeDescriptor >= 0 {
                try? writeHandle.close()
                _ = Darwin.fcntl(writeDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global(qos: .utility).async {
                    writeStdinAndClose(stdin, to: writeDescriptor)
                }
            } else {
                // dup failed (e.g. fd exhaustion). Fall back to a synchronous
                // write on the original handle rather than closing it and
                // letting the child read an empty stream — a silently-empty
                // stdin would let `cat > tmp` succeed and install a 0-byte
                // daemon binary. This rare path blocks the calling thread like
                // the legacy writer did.
                writeStdinSynchronouslyAndClose(stdin, to: writeHandle)
            }
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

    private func duplicateReadDescriptor(_ fileDescriptor: Int32) throws -> Int32 {
        let duplicate = Darwin.dup(fileDescriptor)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return duplicate
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        CMUXDebugLog.logDebugEvent(message())
#endif
    }
}

/// Writes `data` to a blocking pipe write fd and closes it, looping over
/// partial writes and retrying `EINTR`. SIGPIPE must already be suppressed on
/// `fileDescriptor` (`F_SETNOSIGPIPE`); a broken pipe (the remote closed the
/// channel early) simply stops the write, and the process's nonzero exit status
/// then surfaces the failure to the caller. The fd is consumed (closed) here.
/// A file-scope helper (not a closure body) keeps the `errno` read out of the
/// `@Sendable` dispatch closure that streams stdin.
private func writeStdinAndClose(_ data: Data, to fileDescriptor: Int32) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard var cursor = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let written = Darwin.write(fileDescriptor, cursor, remaining)
            if written > 0 {
                cursor = cursor.advanced(by: written)
                remaining -= written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }
    _ = Darwin.close(fileDescriptor)
}

/// Synchronous fallback for the rare case where `dup` of the stdin pipe write
/// end fails: writes `data` on the calling thread and closes the handle, so
/// required stdin is never silently dropped (an empty stream would let the
/// remote `cat > tmp` succeed and install a 0-byte daemon). SIGPIPE is
/// suppressed and the throwing write tolerates an early remote close, which
/// then surfaces as a nonzero exit status.
private func writeStdinSynchronouslyAndClose(_ data: Data, to handle: FileHandle) {
    _ = Darwin.fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    try? handle.write(contentsOf: data)
    try? handle.close()
}

internal import CmuxFoundation
internal import Darwin
internal import Foundation
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
/// Isolation: the struct owns immutable process-input behavior and one optional
/// read-handle observation hook; each `run` call owns its process-local state.
/// The capture readers run on the global utility pool and hand their results
/// through a small queue-confined box, synchronized by the capture
/// `DispatchGroup` before any read-back, exactly like the legacy local-variable
/// captures.
public struct RemoteSessionProcessRunner: RemoteSessionProcessRunning {
    /// Test observation seam (package tests only): invoked right after the
    /// stdout/stderr capture readers are installed, with the pipe read
    /// handles. Return `true` when the hook closes both handles, so the
    /// runner will not close already-closed `FileHandle` instances again.
    /// The capture-survives-teardown regression test uses that to prove
    /// `run` still completes; production constructs the runner without a hook.
    let readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Bool)?
    private let stdinWriter: any RemoteProcessStdinWriting

    /// Creates the production runner.
    public init() {
        self.readHandlesDidInstall = nil
        self.stdinWriter = RemoteProcessStdinWriter()
    }

    init(
        readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Bool)? = nil,
        stdinWriter: any RemoteProcessStdinWriting = RemoteProcessStdinWriter()
    ) {
        self.readHandlesDidInstall = readHandlesDidInstall
        self.stdinWriter = stdinWriter
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
        let stdinFileHandle: FileHandle?
        if let stdinFile = request.stdinFile {
            stdinFileHandle = try FileHandle(forReadingFrom: stdinFile)
        } else {
            stdinFileHandle = nil
        }
        defer { try? stdinFileHandle?.close() }

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

        let writesInlineStdin = stdinFileHandle == nil && stdin != nil
        if let stdinFileHandle {
            process.standardInput = stdinFileHandle
        } else if writesInlineStdin {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "cmux.remote.process.capture")
        let processExitSignal = try RemoteProcessExitSignal()
        let captureStopSignal = try ProcessPipeStopSignal()
        let stdinStopSignal = try ProcessPipeStopSignal()
        let stdinFailureSignal = try ProcessPipeStopSignal()
        let stdinWriteState = RemoteProcessStdinWriteState()
        let captureState = RemoteProcessPipeCaptureState()
        let captureGroup = DispatchGroup()
        let noteProcessExit: @Sendable () -> Void = {
            captureStopSignal.signal()
            processExitSignal.recordExit()
        }
        process.terminationHandler = { _ in
            noteProcessExit()
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
            let result = ProcessPipeStopAwareReader(
                fileDescriptor: stdoutDescriptor,
                stopFileDescriptor: captureStopSignal.readFileDescriptor
            ).readToEnd()
            captureQueue.sync {
                captureState.stdoutData = result.data
                captureState.stdoutReadError = result.readError
            }
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { captureGroup.leave() }
            defer { _ = Darwin.close(stderrDescriptor) }
            let result = ProcessPipeStopAwareReader(
                fileDescriptor: stderrDescriptor,
                stopFileDescriptor: captureStopSignal.readFileDescriptor
            ).readToEnd()
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
            processExitSignal.recordExit()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            captureStopSignal.signal()
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
            stdinStopSignal.signal()
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = processExitSignal.wait(until: .now() + 2.0)
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                noteProcessExit()
            }
        }

        func stdinWriteFailure(_ error: any Error) -> NSError {
            debugLog(
                "remote.proc.stdinWriteFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            return NSError(domain: "cmux.remote.process", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to write stdin for \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
                NSUnderlyingErrorKey: error,
            ])
        }

        let stdinWriteGroup = DispatchGroup()
        if let stdin, let pipe = process.standardInput as? Pipe {
            let inputHandle = pipe.fileHandleForWriting
            stdinWriteGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    try? inputHandle.close()
                    stdinWriteGroup.leave()
                }
                do {
                    try stdinWriter.write(
                        stdin,
                        to: inputHandle,
                        stopFileDescriptor: stdinStopSignal.readFileDescriptor
                    )
                } catch let error as POSIXError where error.code == .EPIPE {
                    // A child may exit before consuming optional stdin. The
                    // POSIX helper turns that race into EPIPE instead of SIGPIPE.
                } catch {
                    stdinWriteState.record(error: error)
                    stdinFailureSignal.signal()
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
        }

        let timeoutDeadline = DispatchTime.now() + max(0, timeout)
        let completionOutcome = RemoteProcessCompletionWaiter(
            processExitFileDescriptor: processExitSignal.readFileDescriptor,
            stdinFailureFileDescriptor: stdinFailureSignal.readFileDescriptor
        ).wait(until: timeoutDeadline)
        var didTimeOut = false
        switch completionOutcome {
        case .processExited:
            break
        case .stdinWriteFailed:
            let stdinWriteError = stdinWriteState.recordedError ?? POSIXError(.EIO)
            if process.isRunning {
                terminateProcessAndWait()
            }
            stdinWriteGroup.wait()
            finishCaptureAndCloseReadHandles()
            throw stdinWriteFailure(stdinWriteError)
        case .timedOut:
            didTimeOut = true
        case .waitFailed(let code):
            stdinStopSignal.signal()
            if process.isRunning {
                terminateProcessAndWait()
            }
            stdinWriteGroup.wait()
            finishCaptureAndCloseReadHandles()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        if didTimeOut, !process.isRunning {
            process.waitUntilExit()
            noteProcessExit()
            didTimeOut = false
        }
        if !didTimeOut {
            didTimeOut = stdinWriteGroup.wait(timeout: timeoutDeadline) == .timedOut
        }

        if didTimeOut {
            if let stdinWriteError = stdinWriteState.recordedError {
                if process.isRunning {
                    terminateProcessAndWait()
                }
                stdinWriteGroup.wait()
                finishCaptureAndCloseReadHandles()
                throw stdinWriteFailure(stdinWriteError)
            }
            stdinStopSignal.signal()
            if let operation, operation.isCancelled {
                if process.isRunning {
                    terminateProcessAndWait()
                }
                stdinWriteGroup.wait()
                finishCaptureAndCloseReadHandles()
                throw operation.cancellationError
            }
            if process.isRunning {
                terminateProcessAndWait()
            }
            stdinWriteGroup.wait()
            finishCaptureAndCloseReadHandles()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        if let stdinWriteError = stdinWriteState.recordedError {
            finishCaptureAndCloseReadHandles()
            throw stdinWriteFailure(stdinWriteError)
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

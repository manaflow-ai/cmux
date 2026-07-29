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
    /// Test observation seam (package tests only): records the launched child
    /// identifier so tests can prove error cleanup reaped that exact process.
    let processDidLaunch: (@Sendable (pid_t) -> Void)?
    /// Test observation seam (package tests only): runs after the child has
    /// definitively exited, including the deadline reconciliation path.
    let processDidExit: (@Sendable () -> Void)?
    private let stdinWriter: any RemoteProcessStdinWriting

    /// Creates the production runner.
    public init() {
        self.readHandlesDidInstall = nil
        self.processDidLaunch = nil
        self.processDidExit = nil
        self.stdinWriter = RemoteProcessStdinWriter()
    }

    init(
        readHandlesDidInstall: (@Sendable (FileHandle, FileHandle) -> Bool)? = nil,
        processDidLaunch: (@Sendable (pid_t) -> Void)? = nil,
        processDidExit: (@Sendable () -> Void)? = nil,
        stdinWriter: any RemoteProcessStdinWriting = RemoteProcessStdinWriter()
    ) {
        self.readHandlesDidInstall = readHandlesDidInstall
        self.processDidLaunch = processDidLaunch
        self.processDidExit = processDidExit
        self.stdinWriter = stdinWriter
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

    private final class ProcessCompletionState: @unchecked Sendable {
        struct Snapshot {
            let didExit: Bool
            let stdinWriteError: (any Error)?
            let stdinWriteFinished: Bool
        }

        private let lock = NSLock()
        private var didExit = false
        private var stdinWriteError: (any Error)?
        private var stdinWriteFinished: Bool
        private var shouldStopStdinWrite = false

        init(stdinWriteFinished: Bool) {
            self.stdinWriteFinished = stdinWriteFinished
        }

        @discardableResult
        func markExited() -> Bool {
            lock.withLock {
                guard !didExit else { return false }
                didExit = true
                return true
            }
        }

        func markStdinWriteFailed(_ error: any Error) {
            lock.withLock {
                stdinWriteError = error
            }
        }

        func markStdinWriteFinished() {
            lock.withLock {
                stdinWriteFinished = true
            }
        }

        func requestStdinWriteStop() {
            lock.withLock {
                shouldStopStdinWrite = true
            }
        }

        func stdinWriteShouldStop() -> Bool {
            lock.withLock {
                shouldStopStdinWrite
            }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    didExit: didExit,
                    stdinWriteError: stdinWriteError,
                    stdinWriteFinished: stdinWriteFinished
                )
            }
        }
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
        let exitSemaphore = DispatchSemaphore(value: 0)
        let lifecycleSemaphore = DispatchSemaphore(value: 0)
        let captureStopSignal = try ProcessPipeStopSignal()
        let completionState = ProcessCompletionState(stdinWriteFinished: !writesInlineStdin)
        let captureState = PipeCaptureState()
        let captureGroup = DispatchGroup()
        let noteProcessExit: @Sendable () -> Void = {
            let isFirstObservation = completionState.markExited()
            captureStopSignal.signal()
            if isFirstObservation {
                processDidExit?()
            }
        }
        process.terminationHandler = { _ in
            noteProcessExit()
            exitSemaphore.signal()
            lifecycleSemaphore.signal()
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
            let result = ProcessPipeEndRead.reading(
                fileDescriptor: stdoutDescriptor,
                stopFileDescriptor: captureStopSignal.readFileDescriptor
            )
            captureQueue.sync {
                captureState.stdoutData = result.data
                captureState.stdoutReadError = result.readError
            }
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { captureGroup.leave() }
            defer { _ = Darwin.close(stderrDescriptor) }
            let result = ProcessPipeEndRead.reading(
                fileDescriptor: stderrDescriptor,
                stopFileDescriptor: captureStopSignal.readFileDescriptor
            )
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
            processDidLaunch?(process.processIdentifier)
        } catch {
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
            completionState.requestStdinWriteStop()
            lifecycleSemaphore.signal()
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
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
                    completionState.markStdinWriteFinished()
                    stdinWriteGroup.leave()
                    lifecycleSemaphore.signal()
                }
                do {
                    try stdinWriter.write(
                        stdin,
                        to: inputHandle,
                        shouldStop: {
                            completionState.stdinWriteShouldStop()
                        }
                    )
                } catch let error as POSIXError where error.code == .EPIPE {
                    // A child may exit before consuming optional stdin. The
                    // POSIX helper turns that race into EPIPE instead of SIGPIPE.
                } catch {
                    completionState.markStdinWriteFailed(error)
                }
            }
        }

        let timeoutDeadline = DispatchTime.now() + max(0, timeout)
        var didTimeOut = false
        while true {
            let state = completionState.snapshot()
            if state.stdinWriteError != nil || (state.didExit && state.stdinWriteFinished) {
                break
            }
            if lifecycleSemaphore.wait(timeout: timeoutDeadline) == .timedOut {
                var stateAtDeadline = completionState.snapshot()
                if !stateAtDeadline.didExit, !process.isRunning {
                    process.waitUntilExit()
                    noteProcessExit()
                    stateAtDeadline = completionState.snapshot()
                }
                didTimeOut = stateAtDeadline.stdinWriteError == nil
                    && !(stateAtDeadline.didExit && stateAtDeadline.stdinWriteFinished)
                if didTimeOut {
                    completionState.requestStdinWriteStop()
                }
                break
            }
        }

        if let stdinWriteError = completionState.snapshot().stdinWriteError {
            if process.isRunning {
                terminateProcessAndWait()
            }
            stdinWriteGroup.wait()
            finishCaptureAndCloseReadHandles()
            throw stdinWriteFailure(stdinWriteError)
        }

        if didTimeOut {
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

        stdinWriteGroup.wait()
        if let stdinWriteError = completionState.snapshot().stdinWriteError {
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

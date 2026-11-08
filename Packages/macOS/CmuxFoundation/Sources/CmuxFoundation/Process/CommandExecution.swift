import Darwin
import Foundation
import os

/// Owns one bounded `Process` invocation and every descriptor used to capture it.
///
/// `CommandRunner` is the public subprocess chokepoint. This lifecycle object
/// keeps its implementation guarantees in one place:
///
/// - every descriptor is close-on-exec before the child launches;
/// - parent pipe endpoints close explicitly instead of waiting for Foundation
///   autorelease pools;
/// - timeout and task cancellation terminate the child and interrupt capture;
/// - the continuation resumes only after both capture readers and the child
///   have finished, all endpoints have closed, and the termination handler has
///   been cleared.
///
/// Safety: every cross-thread mutation is protected by `state`; callback code
/// borrows only immutable descriptors whose ownership stays with this object.
final class CommandExecution: @unchecked Sendable {
    private static let cancellationDescription = "Command cancelled"
    private static let sigkillGraceSeconds: Double = 0.2
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.timer")

    let process: Process
    let stdoutPipe: OwnedProcessPipe
    let stderrPipe: OwnedProcessPipe
    let cancellationSignal: PipeCancellationSignal
    let stdoutReadDescriptor: OwnedFileDescriptor
    let stderrReadDescriptor: OwnedFileDescriptor
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) throws {
        let stdoutPipe = try OwnedProcessPipe()
        let stderrPipe: OwnedProcessPipe
        do {
            stderrPipe = try OwnedProcessPipe()
        } catch {
            stdoutPipe.closeAll()
            throw error
        }
        let cancellationSignal: PipeCancellationSignal
        do {
            cancellationSignal = try PipeCancellationSignal()
        } catch {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            throw error
        }
        let stdoutReadDescriptor: OwnedFileDescriptor
        do {
            stdoutReadDescriptor = try OwnedFileDescriptor(
                duplicating: stdoutPipe.pipe.fileHandleForReading.fileDescriptor
            )
        } catch {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            cancellationSignal.closeAll()
            throw error
        }
        let stderrReadDescriptor: OwnedFileDescriptor
        do {
            stderrReadDescriptor = try OwnedFileDescriptor(
                duplicating: stderrPipe.pipe.fileHandleForReading.fileDescriptor
            )
        } catch {
            stdoutReadDescriptor.close()
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            cancellationSignal.closeAll()
            throw error
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe.pipe
        process.standardError = stderrPipe.pipe
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.cancellationSignal = cancellationSignal
        self.stdoutReadDescriptor = stdoutReadDescriptor
        self.stderrReadDescriptor = stderrReadDescriptor
    }

    deinit {
        process.terminationHandler = nil
        stdoutReadDescriptor.close()
        stderrReadDescriptor.close()
        cancellationSignal.closeAll()
        stdoutPipe.closeAll()
        stderrPipe.closeAll()
    }

    func run(timeout: TimeInterval?) async -> CommandResult {
        if Task.isCancelled {
            closeBeforeLaunch()
            return Self.cancelledResult
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            self.requestEnd(.cancelled)
        }
    }

    private func start(
        timeout: TimeInterval?,
        continuation: CheckedContinuation<CommandResult, Never>
    ) {
        state.withLock { $0.continuation = continuation }
        startCaptureReaders()

        process.terminationHandler = { [weak self] finishedProcess in
            self?.recordTermination(status: finishedProcess.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            cancellationSignal.cancelReaders()
            state.withLock { state in
                if state.endReason == nil {
                    state.endReason = .launchFailure(String(describing: error))
                }
                state.didTerminate = true
                state.didFinishLaunchSetup = true
            }
            completeIfReady()
            return
        }

        // Foundation has duplicated the write endpoints onto the child's
        // stdout/stderr. The parent no longer needs any of the four original
        // Foundation handles, so close them before waiting for callbacks.
        stdoutPipe.closeAll()
        stderrPipe.closeAll()

        let deadlineTimer = timeout.map { timeout in
            CommandTimer(deadline: .now() + max(0, timeout), queue: Self.timerQueue) {
                [weak self] in
                self?.requestEnd(.timedOut)
            }
        }

        let shouldTerminate = state.withLock { state -> Bool in
            state.didLaunch = true
            state.didFinishLaunchSetup = true
            if state.endReason == nil {
                state.deadlineTimer = deadlineTimer
                return false
            }
            return true
        }
        if shouldTerminate {
            deadlineTimer?.cancel()
            terminateRunningProcess()
        }
        completeIfReady()
    }

    private func startCaptureReaders() {
        let cancellationDescriptor = cancellationSignal.readDescriptor
        // `poll`/`read` are blocking POSIX calls and must not occupy Swift's
        // cooperative executor. The utility queue is the blocking-I/O bridge;
        // all lifecycle coordination remains in the lock-backed state below.
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = Self.readToEnd(
                fileDescriptor: stdoutReadDescriptor.rawValue,
                cancellationDescriptor: cancellationDescriptor
            )
            stdoutReadDescriptor.close()
            state.withLock { $0.stdout = data }
            completeIfReady()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = Self.readToEnd(
                fileDescriptor: stderrReadDescriptor.rawValue,
                cancellationDescriptor: cancellationDescriptor
            )
            stderrReadDescriptor.close()
            state.withLock { $0.stderr = data }
            completeIfReady()
        }
    }

    private func requestEnd(_ reason: EndReason) {
        let action = state.withLock { state -> (CommandTimer?, Bool) in
            guard !state.didResume, state.endReason == nil else {
                return (nil, false)
            }
            state.endReason = reason
            let deadlineTimer = state.deadlineTimer
            state.deadlineTimer = nil
            return (deadlineTimer, state.didLaunch)
        }
        action.0?.cancel()
        cancellationSignal.cancelReaders()
        if action.1 {
            terminateRunningProcess()
        }
        completeIfReady()
    }

    private func terminateRunningProcess() {
        guard process.isRunning else { return }

        let killTimer = CommandTimer(
            deadline: .now() + Self.sigkillGraceSeconds,
            queue: Self.timerQueue
        ) { [weak self] in
            self?.forceKillIfStillRunning()
        }
        let shouldTerminate = state.withLock { state -> Bool in
            guard !state.didResume else { return false }
            state.killTimer?.cancel()
            state.killTimer = killTimer
            return true
        }
        guard shouldTerminate else {
            killTimer.cancel()
            return
        }
        process.terminate()
    }

    private func forceKillIfStillRunning() {
        if process.isRunning {
            // `isRunning` ensures the pid still belongs to this Process before
            // the bare pid is used, avoiding a signal after pid reuse.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        state.withLock { state in
            state.killTimer?.cancel()
            state.killTimer = nil
        }
    }

    private func recordTermination(status: Int32) {
        state.withLock { state in
            state.didTerminate = true
            state.exitStatus = status
        }
        completeIfReady()
    }

    private func completeIfReady() {
        let completion = state.withLock { state -> Completion? in
            guard !state.didResume,
                  state.didFinishLaunchSetup,
                  state.didTerminate,
                  let stdout = state.stdout,
                  let stderr = state.stderr,
                  let continuation = state.continuation else {
                return nil
            }
            state.didResume = true
            state.continuation = nil
            let deadlineTimer = state.deadlineTimer
            let killTimer = state.killTimer
            state.deadlineTimer = nil
            state.killTimer = nil
            return Completion(
                continuation: continuation,
                result: Self.result(
                    reason: state.endReason,
                    stdout: stdout,
                    stderr: stderr,
                    exitStatus: state.exitStatus
                ),
                deadlineTimer: deadlineTimer,
                killTimer: killTimer
            )
        }
        guard let completion else { return }

        completion.deadlineTimer?.cancel()
        completion.killTimer?.cancel()
        cancellationSignal.closeAll()
        stdoutPipe.closeAll()
        stderrPipe.closeAll()
        process.terminationHandler = nil
        completion.continuation.resume(returning: completion.result)
    }

    private func closeBeforeLaunch() {
        cancellationSignal.cancelReaders()
        cancellationSignal.closeAll()
        stdoutPipe.closeAll()
        stderrPipe.closeAll()
        stdoutReadDescriptor.close()
        stderrReadDescriptor.close()
        process.standardOutput = nil
        process.standardError = nil
    }

    private static func result(
        reason: EndReason?,
        stdout: Data,
        stderr: Data,
        exitStatus: Int32?
    ) -> CommandResult {
        switch reason {
        case nil:
            return CommandResult(
                stdout: String(data: stdout, encoding: .utf8),
                stderr: String(data: stderr, encoding: .utf8),
                exitStatus: exitStatus,
                timedOut: false,
                executionError: nil
            )
        case .timedOut:
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        case .cancelled:
            return cancelledResult
        case .launchFailure(let message):
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: message
            )
        }
    }

    private static var cancelledResult: CommandResult {
        CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            executionError: cancellationDescription
        )
    }

    private static func readToEnd(
        fileDescriptor: Int32,
        cancellationDescriptor: Int32
    ) -> Data {
        var data = Data()
        var descriptors = [
            pollfd(fd: fileDescriptor, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0),
            pollfd(
                fd: cancellationDescriptor,
                events: Int16(POLLIN | POLLERR | POLLHUP),
                revents: 0
            ),
        ]
        let cancellationEvents = Int16(POLLIN | POLLERR | POLLHUP | POLLNVAL)
        var buffer = [UInt8](repeating: 0, count: FileHandle.processPipeReadChunkSize)

        while true {
            let pollResult = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
            if pollResult < 0 {
                if errno == EINTR { continue }
                return data
            }
            if descriptors[1].revents & cancellationEvents != 0 {
                return data
            }
            let outputEvents = descriptors[0].revents
            if outputEvents & Int16(POLLNVAL) != 0 {
                return data
            }
            guard outputEvents & Int16(POLLIN | POLLERR | POLLHUP) != 0 else {
                continue
            }

            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, pointer.count)
            }
            if bytesRead > 0 {
                buffer.withUnsafeBytes { pointer in
                    guard let baseAddress = pointer.baseAddress else { return }
                    data.append(
                        baseAddress.assumingMemoryBound(to: UInt8.self),
                        count: bytesRead
                    )
                }
            } else if bytesRead == 0 {
                return data
            } else if errno != EINTR {
                return data
            }
        }
    }

    // Safety: this state never escapes `state`'s OSAllocatedUnfairLock.
    private struct State: @unchecked Sendable {
        var continuation: CheckedContinuation<CommandResult, Never>?
        var stdout: Data?
        var stderr: Data?
        var didLaunch = false
        var didFinishLaunchSetup = false
        var didTerminate = false
        var exitStatus: Int32?
        var endReason: EndReason?
        var deadlineTimer: CommandTimer?
        var killTimer: CommandTimer?
        var didResume = false
    }

    private enum EndReason: Sendable {
        case timedOut
        case cancelled
        case launchFailure(String)
    }

    private struct Completion {
        let continuation: CheckedContinuation<CommandResult, Never>
        let result: CommandResult
        let deadlineTimer: CommandTimer?
        let killTimer: CommandTimer?
    }
}

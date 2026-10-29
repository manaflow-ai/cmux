import CmuxNextCompat
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// One child process: `xcrun <arguments>`, or `arguments[0]` itself when
/// the runner has no launcher (the Android SDK's `adb` and `emulator`).
/// ``launch(launcher:arguments:stdin:stdoutFile:captureStdout:spawner:)`` spawns it on a ``ProcessLauncher``
/// queue, never the caller's actor. Exit is observed with the termination handler (no polling); a one-shot
/// `DemandTimer` kills it at its deadline.
final class PhoneProcess: PhoneRunningCommand, Sendable {
    private struct State {
        var status: Int32?
        var waiters: [OnceContinuation<Int32, OnceContinuationError>] = []
        var stdout = Data()
        var stderr = Data()
        /// False while captured stdout can still deliver bytes; a run ends
        /// only after both the exit and the end of its output.
        var outputClosed = true

        var finished: Int32? { outputClosed ? status : nil }
    }

    private let process: Process
    private let state = Mutex(State())
    // timer-class-allow: PhoneProcess is nonisolated: its kill deadline fires off main, DemandTimer's own use
    private let killTimer = DemandTimer(owner: "phone.process.deadline")

    /// Starts one child through `spawner` and returns once it runs; `stdin` is then written without
    /// blocking and closed.
    ///
    /// `@concurrent`: the setup (the stdout file's create and open) never runs on the caller's actor.
    /// - Throws: the launch error, or ``PhoneError/commandFailed(command:status:stderr:)`` for no arguments.
    @concurrent static func launch(launcher: URL?, arguments: [String], stdin: Data?, stdoutFile: URL?,
                                   captureStdout: Bool, spawner: ProcessLauncher) async throws -> PhoneProcess {
        let command = try PhoneProcess(launcher: launcher, arguments: arguments, stdin: stdin != nil,
                                       stdoutFile: stdoutFile, captureStdout: captureStdout)
        try await spawner.launched(command.process)
        if let stdin, let input = command.process.standardInput as? Pipe {
            Self.feed(stdin, to: input, on: DispatchQueue(label: "com.cmuxterm.next.phone-process.stdin",
                                                          qos: WorkPriority(Task.currentPriority).qos))
        }
        return command
    }

    /// Writes `bytes` to the child's standard input on a dispatch channel whose completions run on `queue`,
    /// then closes it: a payload past the pipe's buffer (a large `simctl pbcopy`) never holds a thread until
    /// the child reads it, and a child that exits without reading gets a failed write, not SIGPIPE.
    private static func feed(_ bytes: Data, to input: Pipe, on queue: DispatchQueue) {
        let fd = dup(input.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForWriting.close()
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        let data = bytes.withUnsafeBytes { raw in
            // SAFETY: DispatchData(bytes:) copies raw's bytes during the call, while `bytes` keeps them alive.
            unsafe DispatchData(bytes: raw)
        }
        channel.write(offset: 0, data: data, queue: queue) { done, _, _ in
            if done { channel.close() }
        }
    }

    /// Whether the child still runs.
    var isRunning: Bool { state.withLock { $0.status == nil } }

    /// Configures the child; ``launch(launcher:arguments:stdin:stdoutFile:captureStdout:spawner:)`` starts it.
    private init(launcher: URL?, arguments: [String], stdin: Bool, stdoutFile: URL?, captureStdout: Bool) throws {
        let process = Process()
        if let launcher {
            process.executableURL = launcher
            process.arguments = arguments
        } else {
            guard let tool = arguments.first else { throw PhoneError.commandFailed(command: "(empty)", status: -1, stderr: "") }
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = Array(arguments.dropFirst())
        }
        self.process = process
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.state.withLock { state in
                state.stderr.append(data)
                if state.stderr.count > 16_384 { state.stderr.removeFirst(state.stderr.count - 16_384) }
            }
        }
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            process.standardOutput = try FileHandle.blockingForWriting(to: stdoutFile)
        } else if captureStdout {
            let outPipe = Pipe()
            process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.settle { $0.outputClosed = true }
                    return
                }
                self?.state.withLock { $0.stdout.append(data) }
            }
            state.withLock { $0.outputClosed = false }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        if stdin {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.killTimer.cancel()
            self.settle { $0.status = finished.terminationStatus }
        }
    }

    func interrupt() async {
        guard state.withLock({ $0.status == nil }) else { return }
        process.interrupt()
    }

    func waitForExit(deadline: Duration) async -> Int32 {
        if state.withLock({ $0.status == nil }) {
            killTimer.schedule(after: deadline) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
        // A wait dropped without a status answers -1, "status unknown".
        return (try? await withOnceContinuation { (waiter: OnceContinuation<Int32, OnceContinuationError>) in
            let done = state.withLock { state -> Int32? in
                if let status = state.finished { return status }
                state.waiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }) ?? -1
    }

    /// Applies `change`, then resumes the waiters once the run is finished.
    private func settle(_ change: (inout State) -> Void) {
        let (waiters, status) = state.withLock { state -> ([OnceContinuation<Int32, OnceContinuationError>], Int32?) in
            change(&state)
            guard let status = state.finished else { return ([], nil) }
            defer { state.waiters.removeAll() }
            return (state.waiters, status)
        }
        if let status { for waiter in waiters { waiter.resume(returning: status) } }
    }

    var stdout: Data { state.withLock { $0.stdout } }
    var stderr: String { String(decoding: state.withLock { $0.stderr }, as: UTF8.self) }
}

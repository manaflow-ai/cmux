import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One child process: `xcrun <arguments>`, or `arguments[0]` itself when
/// the runner has no launcher (the Android SDK's `adb` and `emulator`). ``launch(launcher:arguments:stdin:stdoutFile:captureStdout:)``
/// spawns it on a ``ProcessLauncher`` queue at the caller's priority, never the caller's actor, and the child
/// runs at that priority's `processQoS`. Exit is observed with the termination handler (no polling); a
/// one-shot `DemandTimer` kills it at its deadline.
final class PhoneProcess: PhoneRunningCommand, Sendable {
    private struct State {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var stdout = Data()
        var stderr = Data()
        /// False while captured stdout can still deliver bytes; a run ends
        /// only after both the exit and the end of its output.
        var outputClosed = true

        var finished: Int32? { outputClosed ? status : nil }
    }

    private let process: Process
    private let state = Mutex(State())
    private let killTimer = DemandTimer(owner: "phone.process.deadline")

    /// Starts one child and returns once it runs, with `stdin` written and closed.
    /// - Throws: the launch error, or ``PhoneError/commandFailed(command:status:stderr:)`` for no arguments.
    static func launch(launcher: URL?, arguments: [String], stdin: Data?, stdoutFile: URL?,
                       captureStdout: Bool) async throws -> PhoneProcess {
        let command = try PhoneProcess(launcher: launcher, arguments: arguments, stdin: stdin != nil,
                                       stdoutFile: stdoutFile, captureStdout: captureStdout)
        try await ProcessLauncher(label: "com.cmuxterm.next.phone-process", priority: WorkPriority(Task.currentPriority))
            .launched(command.process)
        if let stdin, let input = command.process.standardInput as? Pipe {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        return command
    }

    /// The child's quality of service.
    var qualityOfService: QualityOfService { process.qualityOfService }

    /// Configures the child; ``launch(launcher:arguments:stdin:stdoutFile:captureStdout:)`` starts it.
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
            process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
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
        return await withCheckedContinuation { waiter in
            let done = state.withLock { state -> Int32? in
                if let status = state.finished { return status }
                state.waiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }
    }

    /// Applies `change`, then resumes the waiters once the run is finished.
    private func settle(_ change: (inout State) -> Void) {
        let (waiters, status) = state.withLock { state -> ([CheckedContinuation<Int32, Never>], Int32?) in
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

import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One child process: `xcrun <arguments>`, or `arguments[0]` itself when
/// the runner has no launcher (the Android SDK's `adb` and `emulator`). Exit is observed with the termination handler (no
/// polling); a one-shot `DemandTimer` kills it at its deadline.
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

    init(launcher: URL?, arguments: [String], stdin: Data?, stdoutFile: URL?, captureStdout: Bool) throws {
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
            switch handle.readReady() {
            case .bytes(let data):
                self?.state.withLock { state in
                    state.stderr.append(data)
                    if state.stderr.count > 16_384 { state.stderr.removeFirst(state.stderr.count - 16_384) }
                }
            case .retry: return
            case .end: handle.readabilityHandler = nil
            }
        }
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
        } else if captureStdout {
            let outPipe = Pipe()
            process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                switch handle.readReady() {
                case .bytes(let data): self?.state.withLock { $0.stdout.append(data) }
                case .retry: return
                case .end:
                    handle.readabilityHandler = nil
                    self?.settle { $0.outputClosed = true }
                }
            }
            state.withLock { $0.outputClosed = false }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.killTimer.cancel()
            self.settle { $0.status = finished.terminationStatus }
        }
        try process.run()
        if let inPipe, let stdin {
            // A child that exits without reading closes the read end: the write then fails with
            // EPIPE, which `write(_:)` raises as an uncatchable Objective-C exception, and SIGPIPE
            // would end a process that does not ignore it. Neither is the caller's problem; the
            // child's own exit status tells what went wrong.
            let writer = inPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: stdin)
            try? writer.close()
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

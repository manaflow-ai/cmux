import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One child process: `xcrun <arguments>`, or `arguments[0]` itself when
/// the runner has no launcher (the Android SDK's `adb` and `emulator`). Exit is observed with the termination handler (no
/// polling); a one-shot `DemandTimer` kills it at its deadline. The exit also ends its output: what the
/// pipes still hold is read then, and our read ends close, so a process the child left behind with a
/// write end open can neither hold `waitForExit` nor write into a pipe nobody reads.
final class PhoneProcess: PhoneRunningCommand, Sendable {
    private struct State {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var stdout = Data()
        var stderr = Data()
        /// False while captured stdout can still deliver bytes; a run ends
        /// only after both the exit and the end of its output.
        var outputClosed = true
        /// True once stderr is over for this run (its end of file, or the exit).
        var errorsClosed = false

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
        let errReader = errPipe.fileHandleForReading
        Self.neverWaitInRead(errReader)
        errReader.readabilityHandler = { [weak self] handle in
            guard let self else {
                if handle.readReady() == .end { handle.readabilityHandler = nil }
                return
            }
            if self.take(handle, stderr: true) == .end { handle.readabilityHandler = nil }
        }
        var outReader: FileHandle?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
        } else if captureStdout {
            let outPipe = Pipe()
            process.standardOutput = outPipe
            let reader = outPipe.fileHandleForReading
            Self.neverWaitInRead(reader)
            state.withLock { $0.outputClosed = false }
            reader.readabilityHandler = { [weak self] handle in
                guard let self else {
                    if handle.readReady() == .end { handle.readabilityHandler = nil }
                    return
                }
                guard self.take(handle, stderr: false) == .end else { return }
                handle.readabilityHandler = nil
                self.settle { $0.outputClosed = true }
            }
            outReader = reader
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self, outReader] finished in
            guard let self else { return }
            self.killTimer.cancel()
            self.finishOutput(errReader, stderr: true)
            if let outReader { self.finishOutput(outReader, stderr: false) }
            self.settle { $0.status = finished.terminationStatus }
        }
        try process.run()
        if let inPipe, let stdin {
            // The bytes (a pasteboard of any size) go on the feed's own queue, never this caller's
            // thread: a pipe write waits for the child to read, and this init runs on the main
            // actor before `waitForExit` arms the deadline. Our read end closes first, so a child
            // that exits without reading fails the feed's write (EPIPE; PipeFeed sets
            // F_SETNOSIGPIPE) instead of leaving it waiting.
            try? inPipe.fileHandleForReading.close()
            let feed = PipeFeed(inPipe.fileHandleForWriting)
            feed.write(stdin)
            feed.close()
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

    /// What one read of a pipe gave ``take(_:stderr:)``.
    private enum Took { case bytes, nothing, end }

    /// A read end that never waits in `read`: with nothing ready the read returns at once, so the
    /// exit's last reads (``finishOutput(_:stderr:)``) cannot wait on a write end left open.
    private static func neverWaitInRead(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// One read of a pipe's ready bytes into the state, under its lock: the pipe's handler and the
    /// exit's last reads take the bytes one after the other, in order. `.end` at end of file, on a
    /// failed read, and once the exit closed the pipe (the handle is not read again then).
    private func take(_ handle: FileHandle, stderr: Bool) -> Took {
        state.withLock { state -> Took in
            guard !(stderr ? state.errorsClosed : state.outputClosed) else { return .end }
            switch handle.readReady() {
            case .bytes(let data):
                if stderr {
                    state.stderr.append(data)
                    if state.stderr.count > 16_384 { state.stderr.removeFirst(state.stderr.count - 16_384) }
                } else {
                    state.stdout.append(data)
                }
                return .bytes
            case .retry: return .nothing
            case .end: return .end
            }
        }
    }

    /// The child exited: takes what its pipe holds now, then stops reading it and closes our read
    /// end. Before, a run waited for stdout's end of file with no limit, and a process the child
    /// left behind with the write end open (after the deadline's kill, or a helper it started)
    /// held `waitForExit` for as long as it lived.
    private func finishOutput(_ handle: FileHandle, stderr: Bool) {
        handle.readabilityHandler = nil
        // Bounded (a pipe holds 64 KB): a process left behind that keeps writing cannot hold the exit here.
        for _ in 0..<16 {
            guard take(handle, stderr: stderr) == .bytes else { break }
        }
        state.withLock { state in
            if stderr { state.errorsClosed = true } else { state.outputClosed = true }
        }
        try? handle.close()
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

import Darwin
import Foundation

let cliStdioDispositionLock = NSLock()

enum CLIWriteResult {
    case complete
    case brokenPipe
    case timedOut
}

@discardableResult
func cliWriteIgnoringBrokenPipe(_ data: Data, to fd: Int32, timeout: TimeInterval? = nil) -> Bool {
    cliWriteIgnoringBrokenPipeResult(data, to: fd, timeout: timeout) == .complete
}

@discardableResult
func cliWriteIgnoringBrokenPipeResult(_ data: Data, to fd: Int32, timeout: TimeInterval? = nil) -> CLIWriteResult {
    guard !data.isEmpty else { return .complete }
    let deadline = timeout.map { Date().addingTimeInterval(max(0, $0)) }

    return data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return .complete }
        var offset = 0
        while offset < rawBuffer.count {
            cliStdioDispositionLock.lock()
            let previousHandler = signal(SIGPIPE, SIG_IGN)
            let originalFlags = fcntl(fd, F_GETFL)
            if originalFlags >= 0, originalFlags & O_NONBLOCK == 0 {
                _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
            }
            let bytesWritten = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            let writeErrno = bytesWritten < 0 ? errno : 0
            if originalFlags >= 0, originalFlags & O_NONBLOCK == 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
            }
            _ = signal(SIGPIPE, previousHandler)
            cliStdioDispositionLock.unlock()

            if bytesWritten > 0 {
                offset += bytesWritten
            } else if bytesWritten == -1, writeErrno == EINTR {
                continue
            } else if bytesWritten == -1, writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                while true {
                    if let deadline, Date() >= deadline {
                        return .timedOut
                    }
                    let timeoutMillis: Int32
                    if let deadline {
                        let remainingMillis = Int(max(0, ceil(deadline.timeIntervalSinceNow * 1000)))
                        timeoutMillis = Int32(min(250, remainingMillis))
                    } else {
                        timeoutMillis = 250
                    }
                    let ready = poll(&pollFD, 1, timeoutMillis)
                    if ready > 0 {
                        break
                    }
                    if ready == -1, errno == EINTR {
                        continue
                    }
                    if ready == 0 {
                        continue
                    }
                    return .brokenPipe
                }
                continue
            } else {
                return .brokenPipe
            }
        }
        return .complete
    }
}

@discardableResult
func cliWriteIgnoringBrokenPipe(_ data: Data, to handle: FileHandle, timeout: TimeInterval? = nil) -> Bool {
    cliWriteIgnoringBrokenPipe(data, to: handle.fileDescriptor, timeout: timeout)
}

@discardableResult
func cliWriteIgnoringBrokenPipeResult(_ data: Data, to handle: FileHandle, timeout: TimeInterval? = nil) -> CLIWriteResult {
    cliWriteIgnoringBrokenPipeResult(data, to: handle.fileDescriptor, timeout: timeout)
}

func cliRunProcess(_ process: Process) throws {
    cliStdioDispositionLock.lock()
    defer { cliStdioDispositionLock.unlock() }
    try process.run()
}

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

enum CLIProcessRunner {
    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try cliRunProcess(process)
        } catch {
            return CLIProcessResult(status: 1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let deadline = timeout.map { Date().addingTimeInterval(max(0, $0)) }
        var stdinWriteTimedOut = false
        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                let remaining = deadline.map { max(0, $0.timeIntervalSinceNow) }
                let writeResult = cliWriteIgnoringBrokenPipeResult(data, to: stdinPipe.fileHandleForWriting, timeout: remaining)
                stdinWriteTimedOut = writeResult == .timedOut
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if stdinWriteTimedOut {
            timedOut = true
            terminate(process: process, finished: finished)
        } else if let deadline {
            switch finished.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) {
            case .success:
                timedOut = false
            case .timedOut:
                timedOut = true
                terminate(process: process, finished: finished)
            }
        } else {
            finished.wait()
            timedOut = false
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func terminate(process: Process, finished: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .success {
            return
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = finished.wait(timeout: .now() + 0.5)
    }
}

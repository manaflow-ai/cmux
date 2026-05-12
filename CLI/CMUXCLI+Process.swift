import Darwin
import Foundation

let cliStdioDispositionLock = NSLock()

@discardableResult
func cliWriteIgnoringBrokenPipe(_ data: Data, to fd: Int32) -> Bool {
    guard !data.isEmpty else { return true }

    return data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        var offset = 0
        while offset < rawBuffer.count {
            cliStdioDispositionLock.lock()
            let previousHandler = signal(SIGPIPE, SIG_IGN)
            let bytesWritten = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            let writeErrno = bytesWritten < 0 ? errno : 0
            _ = signal(SIGPIPE, previousHandler)
            cliStdioDispositionLock.unlock()

            if bytesWritten > 0 {
                offset += bytesWritten
            } else if bytesWritten == -1, writeErrno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

@discardableResult
func cliWriteIgnoringBrokenPipe(_ data: Data, to handle: FileHandle) -> Bool {
    cliWriteIgnoringBrokenPipe(data, to: handle.fileDescriptor)
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

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                cliWriteIgnoringBrokenPipe(data, to: stdinPipe.fileHandleForWriting)
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut: Bool
        if let timeout {
            switch finished.wait(timeout: .now() + timeout) {
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

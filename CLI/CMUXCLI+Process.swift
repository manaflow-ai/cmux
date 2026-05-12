import Darwin
import Foundation

let cliStdioDispositionLock = NSLock()

func currentCLINoSIGPIPEValue(for fd: Int32) -> Int32? {
    let value = fcntl(fd, F_GETNOSIGPIPE, 0)
    guard value >= 0 else { return nil }
    return value
}

private func setCLINoSIGPIPE(_ enabled: Bool, for fd: Int32) {
    _ = fcntl(fd, F_SETNOSIGPIPE, enabled ? 1 : 0)
}

func configureCLIWriteFDNoSIGPIPE(_ fd: Int32) {
    guard fd >= 0 else { return }
    setCLINoSIGPIPE(true, for: fd)
}

@discardableResult
func cliWriteIgnoringBrokenPipe(_ data: Data, to handle: FileHandle) -> Bool {
    guard !data.isEmpty else { return true }
    configureCLIWriteFDNoSIGPIPE(handle.fileDescriptor)

    return data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        var offset = 0
        while offset < rawBuffer.count {
            cliStdioDispositionLock.lock()
            let bytesWritten = Darwin.write(
                handle.fileDescriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            let writeErrno = bytesWritten < 0 ? errno : 0
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

private func inheritedCLIWriteFDs(for childEndpoint: Any?, defaultFD: Int32) -> Set<Int32> {
    if childEndpoint == nil {
        return [defaultFD]
    }
    guard let handle = childEndpoint as? FileHandle else {
        return []
    }

    switch handle.fileDescriptor {
    case STDOUT_FILENO, STDERR_FILENO:
        return [handle.fileDescriptor]
    default:
        return []
    }
}

private func childInheritedCLINoSIGPIPEFDs(for process: Process) -> [Int32] {
    let outputFDs = inheritedCLIWriteFDs(for: process.standardOutput, defaultFD: STDOUT_FILENO)
    let errorFDs = inheritedCLIWriteFDs(for: process.standardError, defaultFD: STDERR_FILENO)
    return Array(outputFDs.union(errorFDs)).sorted()
}

func withCLIDefaultSIGPIPEForChildLaunch<T>(
    inheritedNoSIGPIPEFDs: [Int32] = [STDOUT_FILENO, STDERR_FILENO],
    body: () throws -> T
) rethrows -> T {
    cliStdioDispositionLock.lock()
    defer { cliStdioDispositionLock.unlock() }

    let previousValues = inheritedNoSIGPIPEFDs.compactMap { fd -> (fd: Int32, value: Int32)? in
        guard let value = currentCLINoSIGPIPEValue(for: fd) else { return nil }
        if value != 0 {
            setCLINoSIGPIPE(false, for: fd)
        }
        return (fd, value)
    }
    defer {
        for entry in previousValues where entry.value != 0 {
            setCLINoSIGPIPE(true, for: entry.fd)
        }
    }

    return try body()
}

func cliRunProcess(_ process: Process) throws {
    try withCLIDefaultSIGPIPEForChildLaunch(
        inheritedNoSIGPIPEFDs: childInheritedCLINoSIGPIPEFDs(for: process)
    ) {
        try process.run()
    }
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

import CmuxFoundation
import Darwin
import Foundation

enum CLIBrokenPipeDisposition {
    case exit(Int32)
    case ignore
}

private let cliStdioDispositionLock = NSLock()

func currentCLINoSIGPIPEValue(for fd: Int32) -> Int32? {
    let value = fcntl(fd, F_GETNOSIGPIPE, 0)
    guard value >= 0 else { return nil }
    return value
}

private func setCLINoSIGPIPE(_ enabled: Bool, for fd: Int32) {
    _ = fcntl(fd, F_SETNOSIGPIPE, enabled ? 1 : 0)
}

func configureCLIWriteFDNoSIGPIPE(_ fd: Int32) {
    setCLINoSIGPIPE(true, for: fd)
}

private func cliInheritedWriteFD(for childEndpoint: Any?, defaultFD: Int32) -> Int32? {
    if childEndpoint == nil {
        return defaultFD
    }
    guard let handle = childEndpoint as? FileHandle else {
        return nil
    }

    switch handle.fileDescriptor {
    case STDOUT_FILENO, STDERR_FILENO:
        return handle.fileDescriptor
    default:
        return nil
    }
}

private func cliDefaultSIGPIPEWriteHandle(duplicating fd: Int32) throws -> FileHandle {
    let duplicateFD = dup(fd)
    guard duplicateFD >= 0 else {
        throw CLIError(message: "Could not duplicate child stdio fd \(fd): \(String(cString: strerror(errno)))")
    }
    setCLINoSIGPIPE(false, for: duplicateFD)
    return FileHandle(fileDescriptor: duplicateFD, closeOnDealloc: true)
}

private struct CLIProcessStdioOverride {
    let outputHandle: FileHandle?
    let errorHandle: FileHandle?

    func close() {
        try? outputHandle?.close()
        try? errorHandle?.close()
    }
}

private func configureCLIDefaultSIGPIPEStdio(for process: Process) throws -> CLIProcessStdioOverride {
    let originalOutput = process.standardOutput
    let originalError = process.standardError
    let outputFD = cliInheritedWriteFD(for: originalOutput, defaultFD: STDOUT_FILENO)
    let errorFD = cliInheritedWriteFD(for: originalError, defaultFD: STDERR_FILENO)

    let outputHandle = try outputFD.map { try cliDefaultSIGPIPEWriteHandle(duplicating: $0) }
    let errorHandle = try errorFD.map { try cliDefaultSIGPIPEWriteHandle(duplicating: $0) }

    if let outputHandle {
        process.standardOutput = outputHandle
    }
    if let errorHandle {
        process.standardError = errorHandle
    }

    return CLIProcessStdioOverride(
        outputHandle: outputHandle,
        errorHandle: errorHandle
    )
}

func withCLIDefaultSIGPIPEForChildLaunch<T>(
    inheritedNoSIGPIPEFDs: [Int32] = [STDOUT_FILENO, STDERR_FILENO],
    body: () throws -> T
) rethrows -> T {
    guard !inheritedNoSIGPIPEFDs.isEmpty else {
        return try body()
    }

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

func configureCLIStdioNoSIGPIPE() {
    configureCLIWriteFDNoSIGPIPE(STDOUT_FILENO)
    configureCLIWriteFDNoSIGPIPE(STDERR_FILENO)
}

func cliRunProcess(_ process: Process) throws {
    let stdioOverride = try configureCLIDefaultSIGPIPEStdio(for: process)
    defer { stdioOverride.close() }
    try process.run()
}

func cliExecFailureErrno(_ body: () -> Void) -> Int32 {
    withCLIDefaultSIGPIPEForChildLaunch {
        body()
        return errno
    }
}

private func cliWaitForWritableFD(_ fd: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    while true {
        descriptor.revents = 0
        let result = poll(&descriptor, 1, -1)
        if result > 0 {
            let revents = descriptor.revents
            if (revents & Int16(POLLNVAL)) != 0 {
                return false
            }
            // HUP/ERR are useful wakeups: the next write should surface EPIPE
            // or the concrete fd error so the caller's disposition is honored.
            return (revents & Int16(POLLOUT | POLLHUP | POLLERR)) != 0
        }
        if result == 0 {
            return false
        }
        if errno == EINTR {
            continue
        }
        return false
    }
}

private func cliWriteNeedsStdioDispositionLock(_ fd: Int32) -> Bool {
    fd == STDOUT_FILENO || fd == STDERR_FILENO
}

@discardableResult
func cliWrite(_ data: Data, to handle: FileHandle, onBrokenPipe: CLIBrokenPipeDisposition) -> Bool {
    guard !data.isEmpty else { return true }
    let fd = handle.fileDescriptor
    let needsStdioDispositionLock = cliWriteNeedsStdioDispositionLock(fd)
    if !needsStdioDispositionLock {
        configureCLIWriteFDNoSIGPIPE(fd)
    }

    return data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            return true
        }

        var offset = 0
        while offset < rawBuffer.count {
            let written: Int
            let errorCode: Int32
            if needsStdioDispositionLock {
                cliStdioDispositionLock.lock()
                configureCLIWriteFDNoSIGPIPE(fd)
                written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                errorCode = written < 0 ? errno : 0
                cliStdioDispositionLock.unlock()
            } else {
                written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                errorCode = written < 0 ? errno : 0
            }

            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                return false
            }

            switch errorCode {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                guard cliWaitForWritableFD(fd) else {
                    return false
                }
                continue
            case EPIPE:
                switch onBrokenPipe {
                case .exit(let code):
                    Darwin._exit(code)
                case .ignore:
                    return false
                }
            default:
                return false
            }
        }

        return true
    }
}

@discardableResult
func cliWrite(_ text: String, to handle: FileHandle, onBrokenPipe: CLIBrokenPipeDisposition) -> Bool {
    guard let data = text.data(using: .utf8) else { return true }
    return cliWrite(data, to: handle, onBrokenPipe: onBrokenPipe)
}

func cliWriteStdout(_ text: String) {
    _ = cliWrite(text, to: FileHandle.standardOutput, onBrokenPipe: .exit(0))
}

func cliWriteStdout(_ data: Data) {
    _ = cliWrite(data, to: FileHandle.standardOutput, onBrokenPipe: .exit(0))
}

func cliWriteStderr(_ text: String) {
    _ = cliWrite(text, to: FileHandle.standardError, onBrokenPipe: .ignore)
}

func cliWriteStderr(_ data: Data) {
    _ = cliWrite(data, to: FileHandle.standardError, onBrokenPipe: .ignore)
}

private func cliPrintItems(_ items: [Any], separator: String, terminator: String) {
    let body = items.map { String(describing: $0) }.joined(separator: separator)
    cliWriteStdout(body + terminator)
}

func cliPrint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    cliPrintItems(items, separator: separator, terminator: terminator)
}

func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    cliPrintItems(items, separator: separator, terminator: terminator)
}

struct CLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

struct CLIProcessDataResult {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
}

private final class CLIProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

private final class CLIJSONLineResponseBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let responseID: Int
    private let maxBytes: Int
    private var data = Data()
    private var scanOffset = 0
    private var matchedResponse = false
    private var exceededLimit = false

    init(responseID: Int, maxBytes: Int) {
        self.responseID = responseID
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ chunk: Data) -> (matched: Bool, limitExceeded: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard !matchedResponse, !exceededLimit else {
            return (matchedResponse, exceededLimit)
        }

        let remaining = maxBytes - data.count
        if remaining > 0 {
            data.append(contentsOf: chunk.prefix(remaining))
        }

        while scanOffset < data.endIndex,
              let newline = data[scanOffset...].firstIndex(of: 0x0a) {
            let line = data[scanOffset..<newline]
            scanOffset = data.index(after: newline)
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line)
            ) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == responseID else {
                continue
            }
            matchedResponse = true
            break
        }

        if !matchedResponse, chunk.count > remaining {
            exceededLimit = true
        }
        return (matchedResponse, exceededLimit)
    }

    func snapshot() -> (data: Data, matched: Bool, limitExceeded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, matchedResponse, exceededLimit)
    }
}

enum CLIProcessRunner {
    static func runProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        currentDirectoryPath: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        }

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

        let stdoutFinished = DispatchSemaphore(value: 0)
        let stderrFinished = DispatchSemaphore(value: 0)
        let stdoutBuffer = CLIProcessOutputBuffer()
        let stderrBuffer = CLIProcessOutputBuffer()

        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.set(stdoutPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stdoutFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.set(stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stderrFinished.signal()
        }

        do {
            try cliRunProcess(process)
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe?.fileHandleForWriting.close()
            stdoutFinished.wait()
            stderrFinished.wait()
            return CLIProcessResult(status: 1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                _ = cliWrite(data, to: stdinPipe.fileHandleForWriting, onBrokenPipe: .ignore)
            }
            try? stdinPipe.fileHandleForWriting.close()
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

        stdoutFinished.wait()
        stderrFinished.wait()

        let stdout = String(data: stdoutBuffer.get(), encoding: .utf8) ?? ""
        var stderr = String(data: stderrBuffer.get(), encoding: .utf8) ?? ""
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

    static func runProcessData(
        executablePath: String,
        arguments: [String],
        stdinText: String? = nil,
        timeout: TimeInterval? = nil
    ) -> CLIProcessDataResult {
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

        let stdoutFinished = DispatchSemaphore(value: 0)
        let stderrFinished = DispatchSemaphore(value: 0)
        let stdoutBuffer = CLIProcessOutputBuffer()
        let stderrBuffer = CLIProcessOutputBuffer()

        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.set(stdoutPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stdoutFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.set(stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stderrFinished.signal()
        }

        do {
            try cliRunProcess(process)
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe?.fileHandleForWriting.close()
            stdoutFinished.wait()
            stderrFinished.wait()
            return CLIProcessDataResult(status: 1, stdout: Data(), stderr: error.localizedDescription, timedOut: false)
        }

        if let stdinText, let stdinPipe {
            if let data = stdinText.data(using: .utf8) {
                _ = cliWrite(data, to: stdinPipe.fileHandleForWriting, onBrokenPipe: .ignore)
            }
            try? stdinPipe.fileHandleForWriting.close()
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

        stdoutFinished.wait()
        stderrFinished.wait()

        var stderr = String(data: stderrBuffer.get(), encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "process timed out"
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = timeoutMessage
            } else if !stderr.contains(timeoutMessage) {
                stderr += "\n\(timeoutMessage)"
            }
        }

        return CLIProcessDataResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdoutBuffer.get(),
            stderr: stderr,
            timedOut: timedOut
        )
    }

    /// Runs a JSONL process until it emits the requested response id.
    ///
    /// stdin remains open after the requests are written because app servers
    /// may cancel in-flight requests as soon as their transport reaches EOF.
    /// The child is stopped after the matching response, process exit, output
    /// limit, or timeout.
    static func runJSONLinesProcess(
        executablePath: String,
        arguments: [String],
        stdinText: String,
        responseID: Int,
        currentDirectoryPath: String? = nil,
        timeout: TimeInterval,
        maxOutputBytes: Int = 8 * 1024 * 1024
    ) -> CLIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(
                fileURLWithPath: currentDirectoryPath,
                isDirectory: true
            )
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finished = DispatchSemaphore(value: 0)
        let responseOrExit = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
            responseOrExit.signal()
        }

        let stdoutFinished = DispatchSemaphore(value: 0)
        let stderrFinished = DispatchSemaphore(value: 0)
        let stdoutBuffer = CLIJSONLineResponseBuffer(
            responseID: responseID,
            maxBytes: maxOutputBytes
        )
        let stderrBuffer = CLIProcessOutputBuffer()

        DispatchQueue.global(qos: .utility).async {
            var signaledResponse = false
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let chunk: Data
                do {
                    guard let next = try handle.read(upToCount: 64 * 1024),
                          !next.isEmpty else {
                        break
                    }
                    chunk = next
                } catch {
                    break
                }
                let state = stdoutBuffer.append(chunk)
                if !signaledResponse, state.matched || state.limitExceeded {
                    signaledResponse = true
                    responseOrExit.signal()
                }
            }
            stdoutFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.set(stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty())
            stderrFinished.signal()
        }

        do {
            try cliRunProcess(process)
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            stdoutFinished.wait()
            stderrFinished.wait()
            return CLIProcessResult(
                status: 1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }

        if let input = stdinText.data(using: .utf8) {
            _ = cliWrite(
                input,
                to: stdinPipe.fileHandleForWriting,
                onBrokenPipe: .ignore
            )
        }

        let waitResult = responseOrExit.wait(timeout: .now() + timeout)
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            terminate(process: process, finished: finished)
        }

        stdoutFinished.wait()
        stderrFinished.wait()

        let output = stdoutBuffer.snapshot()
        let matchedResponse = output.matched
        let timedOut = waitResult == .timedOut && !matchedResponse
        let stdout = String(data: output.data, encoding: .utf8) ?? ""
        var stderr = String(data: stderrBuffer.get(), encoding: .utf8) ?? ""

        if timedOut {
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = "process timed out"
            } else if !stderr.contains("process timed out") {
                stderr += "\nprocess timed out"
            }
        } else if output.limitExceeded {
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = "process output exceeded \(maxOutputBytes) bytes"
            }
        } else if !matchedResponse,
                  stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stderr = "process exited before JSON response \(responseID)"
        }

        let status: Int32
        if matchedResponse {
            status = 0
        } else if timedOut {
            status = 124
        } else if output.limitExceeded {
            status = 1
        } else {
            status = process.terminationStatus == 0 ? 1 : process.terminationStatus
        }
        return CLIProcessResult(
            status: status,
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

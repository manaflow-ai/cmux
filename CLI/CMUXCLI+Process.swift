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

private typealias CLIJSONLinesReadEvent = (
    standardOutput: Data?,
    standardError: Data?,
    matchedResponse: Bool,
    limitExceeded: Bool,
    error: String?,
    timedOut: Bool
)

private final class CLIJSONLinesChunkReader: @unchecked Sendable {
    enum Stream {
        case standardOutput(
            responseID: Int,
            followupStdinHandle: FileHandle,
            followupStdinText: String?,
            followupAfterResponseID: Int?
        )
        case standardError
    }

    private let handle: FileHandle
    private let stream: Stream
    private let maxOutputBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var lineStart = 0
    private var scanStart = 0
    private var wroteFollowup = false
    private var isConsuming = false
    private var completion: CLIJSONLinesReadEvent?
    private var continuation:
        CheckedContinuation<CLIJSONLinesReadEvent, Never>?

    init(
        handle: FileHandle,
        stream: Stream,
        maxOutputBytes: Int
    ) {
        self.handle = handle
        self.stream = stream
        self.maxOutputBytes = maxOutputBytes
    }

    func read() async -> CLIJSONLinesReadEvent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(returning: completion)
                    return
                }
                self.continuation = continuation
                handle.readabilityHandler = { [weak self] _ in
                    self?.consumeAvailableData()
                }
                lock.unlock()
                // A fast child can write before the readability handler is
                // installed. Drain once immediately so an already-buffered
                // initialize response cannot strand the staged request.
                consumeAvailableData()
            }
        } onCancel: {
            finish((nil, nil, false, false, nil, false))
        }
    }

    private func consumeAvailableData() {
        lock.lock()
        guard completion == nil, !isConsuming else {
            lock.unlock()
            return
        }
        isConsuming = true
        lock.unlock()

        while true {
            lock.lock()
            guard completion == nil else {
                isConsuming = false
                lock.unlock()
                return
            }
            let remaining = max(0, maxOutputBytes - data.count)
            lock.unlock()

            let readLength = min(
                FileHandle.processPipeReadChunkSize,
                remaining + 1
            )
            switch handle.readAvailableData(maxLength: readLength) {
            case .success(.data(let chunk)):
                lock.lock()
                guard completion == nil else {
                    isConsuming = false
                    lock.unlock()
                    return
                }
                let acceptedCount = min(remaining, chunk.count)
                if acceptedCount > 0 {
                    data.append(contentsOf: chunk.prefix(acceptedCount))
                }
                let event = processAcceptedData()
                    ?? (chunk.count > acceptedCount ? limitEvent() : nil)
                if event != nil {
                    isConsuming = false
                }
                lock.unlock()
                if let event {
                    finish(event)
                    return
                }
            case .success(.wouldBlock):
                lock.lock()
                isConsuming = false
                lock.unlock()
                return
            case .success(.endOfFile):
                lock.lock()
                isConsuming = false
                let event = endEvent(error: nil)
                lock.unlock()
                finish(event)
                return
            case .failure(let error):
                lock.lock()
                isConsuming = false
                let event = endEvent(error: error.localizedDescription)
                lock.unlock()
                finish(event)
                return
            }
        }
    }

    /// Must be called while `lock` is held.
    private func processAcceptedData() -> CLIJSONLinesReadEvent? {
        guard case .standardOutput(
            let responseID,
            let followupStdinHandle,
            let followupStdinText,
            let followupAfterResponseID
        ) = stream else {
            return nil
        }

        while scanStart < data.endIndex {
            guard let newline = data[scanStart...].firstIndex(of: 0x0a) else {
                scanStart = data.endIndex
                return nil
            }
            let line = data[lineStart..<newline]
            lineStart = data.index(after: newline)
            scanStart = lineStart
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line)
            ) as? [String: Any],
                let emittedResponseID =
                    (object["id"] as? NSNumber)?.intValue
            else {
                continue
            }
            if !wroteFollowup,
               let followupAfterResponseID,
               emittedResponseID == followupAfterResponseID,
               let followupStdinText {
                guard cliWrite(
                    followupStdinText,
                    to: followupStdinHandle,
                    onBrokenPipe: .ignore
                ) else {
                    return (
                        data,
                        nil,
                        false,
                        false,
                        "process closed stdin before staged JSON input",
                        false
                    )
                }
                wroteFollowup = true
            }
            if emittedResponseID == responseID {
                return (data, nil, true, false, nil, false)
            }
        }
        return nil
    }

    /// Must be called while `lock` is held.
    private func limitEvent() -> CLIJSONLinesReadEvent {
        switch stream {
        case .standardOutput:
            return (data, nil, false, true, nil, false)
        case .standardError:
            return (nil, data, false, true, nil, false)
        }
    }

    /// Must be called while `lock` is held.
    private func endEvent(error: String?) -> CLIJSONLinesReadEvent {
        switch stream {
        case .standardOutput:
            return (data, nil, false, false, error, false)
        case .standardError:
            return (nil, data, false, false, error, false)
        }
    }

    private func finish(_ event: CLIJSONLinesReadEvent) {
        let continuation: CheckedContinuation<
            CLIJSONLinesReadEvent,
            Never
        >?
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        completion = event
        continuation = self.continuation
        self.continuation = nil
        handle.readabilityHandler = nil
        lock.unlock()
        continuation?.resume(returning: event)
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
        followupStdinText: String? = nil,
        followupAfterResponseID: Int? = nil,
        responseID: Int,
        currentDirectoryPath: String? = nil,
        timeout: TimeInterval,
        maxOutputBytes: Int = 8 * 1024 * 1024
    ) async -> CLIProcessResult {
        guard (followupStdinText == nil) == (followupAfterResponseID == nil) else {
            return CLIProcessResult(
                status: 1,
                stdout: "",
                stderr: "staged JSON input requires both a response id and follow-up text",
                timedOut: false
            )
        }

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
        let terminationPair = AsyncStream<Int32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { terminatedProcess in
            terminationPair.continuation.yield(
                terminatedProcess.terminationStatus
            )
            terminationPair.continuation.finish()
        }
        defer {
            process.terminationHandler = nil
            terminationPair.continuation.finish()
        }

        let boundedMaxOutputBytes = max(1, maxOutputBytes)

        do {
            try cliRunProcess(process)
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            return CLIProcessResult(
                status: 1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }

        // Process owns duplicated child endpoints after launch. Close the
        // parent's copies so child exit can produce HUP while stdin remains
        // open through its write endpoint.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let input = stdinText.data(using: .utf8) {
            _ = cliWrite(
                input,
                to: stdinPipe.fileHandleForWriting,
                onBrokenPipe: .ignore
            )
        }

        let boundedTimeout = max(0, min(timeout, 3_600))
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        var stdoutData = Data()
        var stderrData = Data()
        var matchedResponse = false
        var stdoutLimitExceeded = false
        var stderrLimitExceeded = false
        var timedOut = false
        var pipeError: String?
        var finished = false
        var cleanupStarted = false

        func stopChildAndClosePipes() {
            guard !cleanupStarted else { return }
            cleanupStarted = true
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if process.isRunning {
                process.terminate()
            }
        }

        await withTaskGroup(of: CLIJSONLinesReadEvent.self) { group in
            group.addTask {
                await CLIJSONLinesChunkReader(
                    handle: stdoutHandle,
                    stream: .standardOutput(
                        responseID: responseID,
                        followupStdinHandle:
                            stdinPipe.fileHandleForWriting,
                        followupStdinText: followupStdinText,
                        followupAfterResponseID:
                            followupAfterResponseID
                    ),
                    maxOutputBytes: boundedMaxOutputBytes
                ).read()
            }
            group.addTask {
                await CLIJSONLinesChunkReader(
                    handle: stderrHandle,
                    stream: .standardError,
                    maxOutputBytes: boundedMaxOutputBytes
                ).read()
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(
                        for: .seconds(boundedTimeout)
                    )
                } catch {
                    return (nil, nil, false, false, nil, false)
                }
                return (nil, nil, false, false, nil, true)
            }

            while let event = await group.next() {
                if let data = event.standardOutput {
                    stdoutData = data
                    if !finished {
                        matchedResponse = event.matchedResponse
                        stdoutLimitExceeded = event.limitExceeded
                        pipeError = event.error
                        finished = true
                    }
                } else if let data = event.standardError {
                    stderrData = data
                    stderrLimitExceeded = event.limitExceeded
                    if !finished,
                       event.limitExceeded || event.error != nil {
                        pipeError = event.error
                        finished = true
                    }
                } else if event.timedOut {
                    if !finished {
                        timedOut = true
                        finished = true
                    }
                }

                if finished, !cleanupStarted {
                    group.cancelAll()
                    stopChildAndClosePipes()
                }
            }
        }

        stopChildAndClosePipes()
        let childTerminationStatus = await reapJSONLinesProcess(
            process,
            terminationEvents: terminationPair.stream
        )

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if timedOut {
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = "process timed out"
            } else if !stderr.contains("process timed out") {
                stderr += "\nprocess timed out"
            }
        } else if stdoutLimitExceeded || stderrLimitExceeded {
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = "process output exceeded \(boundedMaxOutputBytes) bytes per stream"
            }
        } else if let pipeError {
            if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderr = pipeError
            }
        } else if !matchedResponse,
                  stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stderr = "process exited before JSON response \(responseID)"
        }

        let status: Int32
        if matchedResponse, !stderrLimitExceeded, pipeError == nil {
            status = 0
        } else if timedOut {
            status = 124
        } else if stdoutLimitExceeded || stderrLimitExceeded {
            status = 1
        } else if pipeError != nil {
            status = 1
        } else {
            let childStatus = childTerminationStatus ?? 1
            status = childStatus == 0 ? 1 : childStatus
        }
        return CLIProcessResult(
            status: status,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private typealias CLIProcessTerminationWaitEvent = (
        status: Int32?,
        terminateGraceElapsed: Bool,
        killGraceElapsed: Bool
    )

    /// Reaps the direct child from its Process termination event without
    /// blocking a cooperative Swift thread. Escalate once if orderly
    /// termination does not complete promptly, while keeping cleanup bounded.
    private static func reapJSONLinesProcess(
        _ process: Process,
        terminationEvents: AsyncStream<Int32>
    ) async -> Int32? {
        await withTaskGroup(of: CLIProcessTerminationWaitEvent.self) { group in
            group.addTask {
                var iterator = terminationEvents.makeAsyncIterator()
                guard let status = await iterator.next() else {
                    return (nil, false, false)
                }
                return (status, false, false)
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: .milliseconds(100))
                } catch {
                    return (nil, false, false)
                }
                return (nil, true, false)
            }

            while let event = await group.next() {
                if let status = event.status {
                    group.cancelAll()
                    return status
                }
                if event.terminateGraceElapsed {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    group.addTask {
                        do {
                            try await ContinuousClock().sleep(
                                for: .milliseconds(400)
                            )
                        } catch {
                            return (nil, false, false)
                        }
                        return (nil, false, true)
                    }
                } else if event.killGraceElapsed {
                    group.cancelAll()
                    return nil
                } else if Task.isCancelled {
                    group.cancelAll()
                    return nil
                }
            }
            return process.isRunning ? nil : process.terminationStatus
        }
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

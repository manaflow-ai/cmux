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

func configureCLIStdioNoSIGPIPE() {
    configureCLIWriteFDNoSIGPIPE(STDOUT_FILENO)
    configureCLIWriteFDNoSIGPIPE(STDERR_FILENO)
}

func cliRunProcess(_ process: Process) throws {
    try withCLIDefaultSIGPIPEForChildLaunch(
        inheritedNoSIGPIPEFDs: childInheritedCLINoSIGPIPEFDs(for: process)
    ) {
        try process.run()
    }
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

extension CMUXCLI {
    private static func currentSIGPIPEDispositionName() -> String {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0 else {
            return "error"
        }
        if (Int32(current.sa_flags) & SA_SIGINFO) != 0 {
            return "custom"
        }
        let handlerBits = unsafeBitCast(current.__sigaction_u.__sa_handler, to: UInt.self)
        let sigIgnBits = unsafeBitCast(SIG_IGN, to: UInt.self)
        let sigDflBits = unsafeBitCast(SIG_DFL, to: UInt.self)
        if handlerBits == sigIgnBits {
            return "ignored"
        }
        if handlerBits == sigDflBits {
            return "default"
        }
        return "custom"
    }

    static func currentSIGPIPEInspectionPayload() -> [String: Any] {
        [
            "signal": currentSIGPIPEDispositionName(),
            "stdout_nosigpipe": Int(currentCLINoSIGPIPEValue(for: STDOUT_FILENO) ?? -1),
            "stderr_nosigpipe": Int(currentCLINoSIGPIPEValue(for: STDERR_FILENO) ?? -1),
        ]
    }

    private func sigpipeProbeExecutablePath() throws -> String {
        let candidate: String? = {
            if let explicit = ProcessInfo.processInfo.environment["CMUX_CLI_PATH"],
               !explicit.isEmpty {
                return explicit
            }
            return CommandLine.arguments.first
        }()
        guard let path = candidate,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError(message: "SIGPIPE probe could not resolve cmux executable path")
        }
        return path
    }

    func runSIGPIPEInspect(commandArgs: [String]) throws {
        let outputPath: String?
        switch commandArgs.count {
        case 0:
            outputPath = nil
        case 2 where commandArgs[0] == "--out":
            outputPath = commandArgs[1]
        default:
            throw CLIError(message: "Unknown SIGPIPE inspect arguments. Expected no args or --out <path>.")
        }

        let payload = initialSIGPIPEInspectionPayload ?? Self.currentSIGPIPEInspectionPayload()
        let output = jsonString(payload)
        if let outputPath {
            try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } else {
            cliWriteStdout(output + "\n")
        }
    }

    func runSIGPIPEStdinPipeProbe() throws {
        let payload = String(repeating: "x", count: 1_048_576)
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/zsh",
            arguments: ["-lc", "exec </dev/null; sleep 0.05"],
            stdinText: payload,
            timeout: 5
        )
        guard !result.timedOut else {
            throw CLIError(message: "SIGPIPE stdin-pipe probe timed out: \(result.stderr)")
        }
        guard result.status == 0 else {
            throw CLIError(message: "SIGPIPE stdin-pipe probe failed (\(result.status)): \(result.stderr)")
        }
        cliPrint("ok")
    }

    func runSIGPIPENonStdioLockProbe() throws {
        func setNonBlocking(_ fd: Int32, _ enabled: Bool) throws {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0 else {
                throw CLIError(message: "SIGPIPE non-stdio lock probe could not read fd flags: \(String(cString: strerror(errno)))")
            }

            let nextFlags = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
            guard fcntl(fd, F_SETFL, nextFlags) == 0 else {
                throw CLIError(message: "SIGPIPE non-stdio lock probe could not update fd flags: \(String(cString: strerror(errno)))")
            }
        }

        func fillPipeUntilFull(writeFD: Int32) throws {
            var buffer = [UInt8](repeating: 0x78, count: 4096)
            while true {
                let written = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.write(writeFD, rawBuffer.baseAddress, rawBuffer.count)
                }
                if written > 0 {
                    continue
                }
                if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                throw CLIError(message: "SIGPIPE non-stdio lock probe could not fill pipe: \(String(cString: strerror(errno)))")
            }
        }

        var pipeFDs = [Int32](repeating: 0, count: 2)
        guard pipe(&pipeFDs) == 0 else {
            throw CLIError(message: "SIGPIPE non-stdio lock probe could not create pipe: \(String(cString: strerror(errno)))")
        }

        var readFD: Int32? = pipeFDs[0]
        let writeHandle = FileHandle(fileDescriptor: pipeFDs[1], closeOnDealloc: false)
        defer {
            if let fd = readFD {
                Darwin.close(fd)
            }
            try? writeHandle.close()
        }

        try setNonBlocking(writeHandle.fileDescriptor, true)
        try fillPipeUntilFull(writeFD: writeHandle.fileDescriptor)
        try setNonBlocking(writeHandle.fileDescriptor, false)

        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            writerStarted.signal()
            _ = cliWrite(Data([0x79]), to: writeHandle, onBrokenPipe: .ignore)
            writerFinished.signal()
        }

        guard writerStarted.wait(timeout: .now() + 1) == .success else {
            throw CLIError(message: "SIGPIPE non-stdio lock probe writer did not start")
        }
        guard writerFinished.wait(timeout: .now() + 0.1) == .timedOut else {
            throw CLIError(message: "SIGPIPE non-stdio lock probe writer did not block")
        }

        let launchFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/true",
                arguments: [],
                timeout: 2
            )
            launchFinished.signal()
        }

        let launchResult = launchFinished.wait(timeout: .now() + 1)
        if let fd = readFD {
            Darwin.close(fd)
            readFD = nil
        }

        guard writerFinished.wait(timeout: .now() + 1) == .success else {
            throw CLIError(message: "SIGPIPE non-stdio lock probe writer did not unblock")
        }
        guard launchResult == .success else {
            _ = launchFinished.wait(timeout: .now() + 1)
            throw CLIError(message: "SIGPIPE non-stdio lock probe child launch was blocked by the stdio disposition lock")
        }

        cliPrint("ok")
    }

    func runSIGPIPEProbe(commandArgs: [String]) throws {
        let mode = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "spawn"
        let cliPath = try sigpipeProbeExecutablePath()
        let inspectionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sigpipe-\(UUID().uuidString).json")
        let inspectionPath = inspectionURL.path
        let inspectFileArguments = ["__sigpipe-inspect", "--out", inspectionPath]
        defer {
            try? FileManager.default.removeItem(at: inspectionURL)
        }

        switch mode {
        case "spawn":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = inspectFileArguments
            process.standardInput = FileHandle.nullDevice
            try cliRunProcess(process)
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw CLIError(message: "SIGPIPE spawn probe failed (\(process.terminationStatus))")
            }

            let output = try String(contentsOf: inspectionURL, encoding: .utf8)
            cliWriteStdout(output + (output.hasSuffix("\n") ? "" : "\n"))

        case "spawn-stderr":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = inspectFileArguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
            try cliRunProcess(process)
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw CLIError(message: "SIGPIPE stderr-spawn probe failed (\(process.terminationStatus))")
            }

            let output = try String(contentsOf: inspectionURL, encoding: .utf8)
            cliWriteStdout(output + (output.hasSuffix("\n") ? "" : "\n"))

        case "exec":
            let execArguments = [cliPath, "__sigpipe-inspect"]
            var argv: [UnsafeMutablePointer<CChar>?] = execArguments.map { strdup($0) }
            defer {
                for item in argv {
                    free(item)
                }
            }
            argv.append(nil)

            let code = cliExecFailureErrno {
                _ = argv.withUnsafeMutableBufferPointer { buffer in
                    execv(cliPath, buffer.baseAddress)
                }
            }
            throw CLIError(message: "SIGPIPE exec probe failed: \(String(cString: strerror(code)))")

        default:
            throw CLIError(message: "Unknown SIGPIPE probe mode '\(mode)'. Expected spawn, spawn-stderr, or exec.")
        }
    }
}

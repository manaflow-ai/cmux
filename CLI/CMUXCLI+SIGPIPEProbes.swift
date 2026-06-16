import Darwin
import Foundation

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

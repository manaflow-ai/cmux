import Darwin
import Foundation

extension CMUXCLI {
    func configureCLISocketNoSIGPIPE(fileDescriptor fd: Int32, failureMessage: @autoclosure () -> String) throws {
#if os(macOS)
        var noSigPipe: Int32 = 1
        let result = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: failureMessage())
        }
#endif
    }

    func acceptCLISocketNoSIGPIPE(
        _ serverFD: Int32,
        acceptFailureMessage: @autoclosure () -> String,
        noSIGPIPEFailureMessage: @autoclosure () -> String
    ) throws -> Int32? {
        let clientFD = accept(serverFD, nil, nil)
        if clientFD < 0 {
            if errno == EINTR {
                return nil
            }
            throw CLIError(message: acceptFailureMessage())
        }
        do {
            try configureCLISocketNoSIGPIPE(fileDescriptor: clientFD, failureMessage: noSIGPIPEFailureMessage())
            return clientFD
        } catch {
            Darwin.close(clientFD)
            throw error
        }
    }

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
        var isDirectory: ObjCBool = false
        guard let path = candidate,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
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

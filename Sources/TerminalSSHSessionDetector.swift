import Foundation
import Darwin

struct DetectedSSHSession: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let configFile: String?
    let jumpHost: String?
    let controlPath: String?
    let useIPv4: Bool
    let useIPv6: Bool
    let forwardAgent: Bool
    let compressionEnabled: Bool
    let sshOptions: [String]

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let session = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let remotePaths = try session.uploadDroppedFilesSync(fileURLs, operation: operation)
                try operation.throwIfCancelled()
                return remotePaths
            }
            DispatchQueue.main.async {
                if operation.isCancelled {
                    completion(.failure(TerminalImageTransferExecutionError.cancelled))
                } else {
                    completion(result)
                }
            }
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFiles(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

    private func uploadDroppedFilesSync(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation
    ) throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        return try fileURLs.map { localURL in
            try operation.throwIfCancelled()
            let normalizedLocalURL = localURL.standardizedFileURL
            guard normalizedLocalURL.isFileURL else {
                throw NSError(domain: "cmux.detected-ssh.drop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "dropped item is not a file URL",
                ])
            }

            let remotePath = WorkspaceRemoteSessionController.remoteDropPath(for: normalizedLocalURL)
            let result = try Self.runProcess(
                executable: "/usr/bin/scp",
                arguments: scpArguments(localPath: normalizedLocalURL.path, remotePath: remotePath),
                timeout: 45,
                operation: operation
            )
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ??
                    "scp exited \(result.status)"
                throw NSError(domain: "cmux.detected-ssh.drop", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "failed to upload dropped file: \(detail)",
                ])
            }

            return remotePath
        }
    }

    private func scpArguments(localPath: String, remotePath: String) -> [String] {
        var args: [String] = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-P", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [localPath, "\(destination):\(remotePath)"]
        return args
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try operation?.throwIfCancelled()
        try process.run()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        func terminateProcessAndWait() {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        if exitSignal.wait(timeout: .now() + timeout) == .timedOut {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            throw NSError(domain: "cmux.detected-ssh.drop", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "scp timed out",
            ])
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func bestErrorLine(stderr: String, stdout: String) -> String? {
        let stderrLine = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let stderrLine {
            return stderrLine
        }

        return stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { optionKey($0) == loweredKey }
    }

    private static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

#if DEBUG
    func scpArgumentsForTesting(localPath: String, remotePath: String) -> [String] {
        scpArguments(localPath: localPath, remotePath: remotePath)
    }
#endif
}

enum TerminalSSHSessionDetector {
    struct ProcessSnapshot: Equatable {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tty: String
        let executableName: String
    }

    static func detect(forTTY ttyName: String) -> DetectedSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }
        let processes = processSnapshots(forTTY: normalizedTTY)
        guard !processes.isEmpty else { return nil }

        var argumentsByPID: [Int32: [String]] = [:]
        for process in processes where isForegroundSSHProcess(process, ttyName: normalizedTTY) {
            if let args = commandLineArguments(forPID: process.pid) {
                argumentsByPID[process.pid] = args
            }
        }

        return detectForTesting(
            ttyName: normalizedTTY,
            processes: processes,
            argumentsByPID: argumentsByPID
        )
    }

    static func detectForTesting(
        ttyName: String,
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> DetectedSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let candidates = processes
            .filter { isForegroundSSHProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            guard let arguments = argumentsByPID[candidate.pid],
                  let session = parseSSHCommandLine(arguments) else {
                continue
            }
            return session
        }

        return nil
    }

    private static let psPath = "/bin/ps"
    private static let noArgumentFlags = Set("46AaCfGgKkMNnqsTtVvXxYy")
    private static let valueArgumentFlags = Set("BbcDEeFIiJLlmOopQRSWw")
    private static let filteredSSHOptionKeys: Set<String> = [
        "batchmode",
        "controlmaster",
        "controlpersist",
        "forkafterauthentication",
        "localcommand",
        "permitlocalcommand",
        "remotecommand",
        "requesttty",
        "sendenv",
        "sessiontype",
        "setenv",
        "stdioforward",
    ]

    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let lastComponent = trimmed.split(separator: "/").last {
            return String(lastComponent)
        }
        return trimmed
    }

    private static func isForegroundSSHProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizeTTYName(process.tty) == normalizeTTYName(ttyName) &&
            process.executableName == "ssh" &&
            process.pgid > 0 &&
            process.tpgid > 0 &&
            process.pgid == process.tpgid
    }

    private static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: psPath)
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,tty=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap(parseProcessSnapshot)
    }

    private static func parseProcessSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let pgid = Int32(parts[1]),
              let tpgid = Int32(parts[2]) else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid,
            pgid: pgid,
            tpgid: tpgid,
            tty: String(parts[3]),
            executableName: String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func commandLineArguments(forPID pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }

        return parseKernProcArgs(Array(buffer.prefix(Int(size))))
    }

    private static func parseKernProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(4))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = 4
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            while index < bytes.count, bytes[index] == 0 {
                index += 1
            }
        }

        return arguments.count == argc ? arguments : nil
    }

    private static func parseSSHCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if let executable = arguments.first?.split(separator: "/").last,
           executable == "ssh" {
            index = 1
        }

        var destination: String?
        var port: Int?
        var identityFile: String?
        var configFile: String?
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        var useIPv4 = false
        var useIPv6 = false
        var forwardAgent = false
        var compressionEnabled = false
        var sshOptions: [String] = []

        func consumeValue(_ value: String, for option: Character) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }

            switch option {
            case "p":
                guard let parsedPort = Int(trimmedValue) else { return false }
                port = parsedPort
                return true
            case "i":
                identityFile = trimmedValue
                return true
            case "F":
                configFile = trimmedValue
                return true
            case "J":
                jumpHost = trimmedValue
                return true
            case "S":
                controlPath = trimmedValue
                return true
            case "l":
                loginName = trimmedValue
                return true
            case "o":
                return consumeSSHOption(
                    trimmedValue,
                    port: &port,
                    identityFile: &identityFile,
                    controlPath: &controlPath,
                    jumpHost: &jumpHost,
                    loginName: &loginName,
                    sshOptions: &sshOptions
                )
            default:
                return valueArgumentFlags.contains(option)
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                if index < arguments.count {
                    destination = arguments[index]
                }
                break
            }
            if !argument.hasPrefix("-") || argument == "-" {
                destination = argument
                break
            }

            if argument.count > 2,
               let option = argument.dropFirst().first,
               valueArgumentFlags.contains(option) {
                guard consumeValue(String(argument.dropFirst(2)), for: option) else { return nil }
                index += 1
                continue
            }

            if argument.count == 2,
               let optionCharacter = argument.dropFirst().first,
               valueArgumentFlags.contains(optionCharacter) {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      consumeValue(arguments[nextIndex], for: optionCharacter) else {
                    return nil
                }
                index += 2
                continue
            }

            let flags = Array(argument.dropFirst())
            guard !flags.isEmpty, flags.allSatisfy({ noArgumentFlags.contains($0) }) else {
                return nil
            }
            for flag in flags {
                switch flag {
                case "4":
                    useIPv4 = true
                    useIPv6 = false
                case "6":
                    useIPv6 = true
                    useIPv4 = false
                case "A":
                    forwardAgent = true
                case "C":
                    compressionEnabled = true
                default:
                    break
                }
            }
            index += 1
        }

        guard let destination else { return nil }
        let finalDestination = resolveDestination(destination, loginName: loginName)
        guard !finalDestination.isEmpty else { return nil }

        return DetectedSSHSession(
            destination: finalDestination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            useIPv4: useIPv4,
            useIPv6: useIPv6,
            forwardAgent: forwardAgent,
            compressionEnabled: compressionEnabled,
            sshOptions: sshOptions
        )
    }

    private static func consumeSSHOption(
        _ option: String,
        port: inout Int?,
        identityFile: inout String?,
        controlPath: inout String?,
        jumpHost: inout String?,
        loginName: inout String?,
        sshOptions: inout [String]
    ) -> Bool {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = sshOptionKey(trimmed)
        let value = sshOptionValue(trimmed)

        switch key {
        case "port":
            if let value, let parsedPort = Int(value) {
                port = parsedPort
                return true
            }
            return false
        case "identityfile":
            if let value, !value.isEmpty {
                identityFile = value
                return true
            }
            return false
        case "controlpath":
            if let value, !value.isEmpty {
                controlPath = value
                return true
            }
            return false
        case "proxyjump":
            if let value, !value.isEmpty {
                jumpHost = value
                return true
            }
            return false
        case "user":
            if let value, !value.isEmpty {
                loginName = value
                return true
            }
            return false
        case let key? where filteredSSHOptionKeys.contains(key):
            return true
        case .some, .none:
            sshOptions.append(trimmed)
            return true
        }
    }

    private static func resolveDestination(_ destination: String, loginName: String?) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return "" }
        guard let loginName = loginName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginName.isEmpty,
              !trimmedDestination.contains("@") else {
            return trimmedDestination
        }
        return "\(loginName)@\(trimmedDestination)"
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func sshOptionValue(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let equalIndex = trimmed.firstIndex(of: "=") {
            let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

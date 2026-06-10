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
            let result: Result<[String], Error>
            do {
                let remotePaths = try session.uploadDroppedFilesSync(fileURLs, operation: operation)
                do {
                    try operation.throwIfCancelled()
                    result = .success(remotePaths)
                } catch {
                    session.cleanupUploadedRemotePathsAsync(remotePaths)
                    result = .failure(error)
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                if operation.isCancelled {
                    if case .success(let remotePaths) = result {
                        session.cleanupUploadedRemotePathsAsync(remotePaths)
                    }
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

#if DEBUG
    typealias ProcessOverrideResultForTesting = (
        status: Int32,
        stdout: String,
        stderr: String
    )

    static var runProcessOverrideForTesting: ((
        String,
        [String],
        TimeInterval,
        TerminalImageTransferOperation?
    ) throws -> ProcessOverrideResultForTesting)?

    func uploadDroppedFilesSyncForTesting(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation = TerminalImageTransferOperation()
    ) throws -> [String] {
        try uploadDroppedFilesSync(fileURLs, operation: operation)
    }
#endif

    private func uploadDroppedFilesSync(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation
    ) throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        var uploadedRemotePaths: [String] = []
        do {
            for localURL in fileURLs {
                try operation.throwIfCancelled()
                let normalizedLocalURL = localURL.standardizedFileURL
                guard normalizedLocalURL.isFileURL else {
                    throw NSError(domain: "cmux.detected-ssh.drop", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "detectedSSH.fileDrop.error.notFileURL",
                            defaultValue: "Couldn't upload the dropped item because it isn't a local file. Drop a file from Finder, then try again."
                        ),
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
                    throw NSError(domain: "cmux.detected-ssh.drop", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "detectedSSH.fileDrop.error.uploadFailed",
                            defaultValue: "Couldn't upload the file to the remote session. Check that the remote host is reachable, then try again."
                        ),
                    ])
                }

                uploadedRemotePaths.append(remotePath)
            }

            return uploadedRemotePaths
        } catch {
            cleanupUploadedRemotePaths(uploadedRemotePaths)
            throw error
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

        args += [localPath, "\(Self.scpRemoteDestination(destination)):\(remotePath)"]
        return args
    }

    private func sshArguments(command: String) -> [String] {
        var args: [String] = [
            "-T",
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
            args += ["-p", String(port)]
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

        args += [destination, command]
        return args
    }

    private func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(Self.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(Self.shellSingleQuoted(cleanupScript))"
        _ = try? Self.runProcess(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(command: cleanupCommand),
            timeout: 8
        )
    }

    private func cleanupUploadedRemotePathsAsync(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let session = self
        DispatchQueue.global(qos: .utility).async {
            session.cleanupUploadedRemotePaths(remotePaths)
        }
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
#if DEBUG
        if let runProcessOverrideForTesting {
            let result = try runProcessOverrideForTesting(executable, arguments, timeout, operation)
            return CommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
        }
#endif

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
                NSLocalizedDescriptionKey: String(
                    localized: "detectedSSH.fileDrop.error.scpTimedOut",
                    defaultValue: "File transfer timed out. Check the remote host and network connection, then try again."
                ),
            ])
        }

        let stdout = String(
            data: ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdoutPipe.fileHandleForReading),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stderrPipe.fileHandleForReading),
            encoding: .utf8
        ) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
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

    private static func scpRemoteDestination(_ destination: String) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return destination }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmedDestination
        }

        guard shouldBracketIPv6Literal(hostPart) else {
            return trimmedDestination
        }

        let bracketedHost = "[\(hostPart)]"
        if let userPart {
            return "\(userPart)@\(bracketedHost)"
        }
        return bracketedHost
    }

    private static func shouldBracketIPv6Literal(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

#if DEBUG
    func scpArgumentsForTesting(localPath: String, remotePath: String) -> [String] {
        scpArguments(localPath: localPath, remotePath: remotePath)
    }
#endif
}

struct DetectedRemoteTerminalSession: Equatable, Sendable {
    enum Transport: String, Sendable {
        case ssh
        case mosh
        case osc7
    }

    let transport: Transport
    let destination: String?
    let directory: String?

    init(transport: Transport, destination: String?, directory: String?) {
        self.transport = transport
        let trimmedDestination = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.destination = trimmedDestination.isEmpty ? nil : trimmedDestination
        let trimmedDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.directory = trimmedDirectory.isEmpty ? nil : trimmedDirectory
    }

    static func ssh(_ session: DetectedSSHSession) -> DetectedRemoteTerminalSession {
        DetectedRemoteTerminalSession(
            transport: .ssh,
            destination: session.destination,
            directory: nil
        )
    }

    static func ssh(destination: String?) -> DetectedRemoteTerminalSession {
        DetectedRemoteTerminalSession(
            transport: .ssh,
            destination: destination,
            directory: nil
        )
    }

    static func mosh(destination: String?) -> DetectedRemoteTerminalSession {
        DetectedRemoteTerminalSession(
            transport: .mosh,
            destination: destination,
            directory: nil
        )
    }

    static func osc7(host: String, directory: String) -> DetectedRemoteTerminalSession {
        DetectedRemoteTerminalSession(
            transport: .osc7,
            destination: host,
            directory: directory
        )
    }

    var displayDirectory: String {
        if let directory {
            guard let destination else { return directory }
            return "\(destination):\(directory)"
        }
        return displayTitle
    }

    var displayTitle: String {
        if directory != nil {
            return displayDirectory
        }
        switch transport {
        case .ssh:
            if let destination {
                return "ssh \(destination)"
            }
            return String(localized: "remoteSession.title.sshFallback", defaultValue: "SSH session")
        case .mosh:
            if let destination {
                return "mosh \(destination)"
            }
            return String(localized: "remoteSession.title.moshFallback", defaultValue: "mosh session")
        case .osc7:
            if let destination {
                return destination
            }
            return String(localized: "remoteSession.title.remoteFallback", defaultValue: "Remote session")
        }
    }

    static func fromReportedDirectory(
        _ rawDirectory: String,
        localHostNames: Set<String>? = nil
    ) -> DetectedRemoteTerminalSession? {
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "file" || scheme == "kitty-shell-cwd" else {
            return nil
        }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        let hostNames = localHostNames ?? cachedLocalHostNames
        guard !isLocalHost(host, localHostNames: hostNames) else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return .osc7(host: host, directory: path)
    }

    private static let cachedLocalHostNames: Set<String> = localHostNames()

    static func localHostNames() -> Set<String> {
        var names: Set<String> = [
            "localhost",
            "127.0.0.1",
            "::1",
            ProcessInfo.processInfo.hostName,
        ]
        if let name = Host.current().name {
            names.insert(name)
        }
        if let localizedName = Host.current().localizedName {
            names.insert(localizedName)
        }

        var normalized: Set<String> = []
        for name in names {
            let value = normalizedHostName(name)
            guard !value.isEmpty else { continue }
            normalized.insert(value)
            if value.hasSuffix(".local") {
                normalized.insert(String(value.dropLast(".local".count)))
            }
        }
        return normalized
    }

    private static func isLocalHost(_ host: String, localHostNames: Set<String>) -> Bool {
        let normalized = normalizedHostName(host)
        guard !normalized.isEmpty else { return false }
        if localHostNames.contains(normalized) {
            return true
        }
        if normalized.hasSuffix(".local"),
           localHostNames.contains(String(normalized.dropLast(".local".count))) {
            return true
        }
        return false
    }

    private static func normalizedHostName(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }
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
        let normalizedTTY = normalizedTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }
        let processes = processSnapshots(forTTY: normalizedTTY)
        guard !processes.isEmpty else { return nil }

        var argumentsByPID: [Int32: [String]] = [:]
        for process in processes where isForegroundRemoteShellProcess(process, ttyName: normalizedTTY) {
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
        let normalizedTTY = normalizedTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let candidates = processes
            .filter { isForegroundRemoteShellProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            guard let transport = RemoteShellTransport(executableName: candidate.executableName),
                  let arguments = argumentsByPID[candidate.pid],
                  let session = parseCommandLine(arguments, for: transport) else {
                continue
            }
            return session
        }

        return nil
    }

    static func detectRemoteSessionForTesting(
        ttyName: String,
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> DetectedRemoteTerminalSession? {
        let normalizedTTY = normalizedTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let candidates = processes
            .filter { isForegroundRemoteProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            switch candidate.executableName {
            case "ssh":
                guard let arguments = argumentsByPID[candidate.pid] else {
                    return .ssh(destination: nil)
                }
                if let session = parseSSHCommandLine(arguments) {
                    return .ssh(session)
                }
                continue
            case "mosh":
                let destination = argumentsByPID[candidate.pid].flatMap(parseMoshCommandLine)
                return .mosh(destination: destination)
            case "mosh-client":
                return .mosh(destination: nil)
            default:
                continue
            }
        }

        return nil
    }

    static func detectRemoteSession(commandLine: String) -> DetectedRemoteTerminalSession? {
        for segment in shellCommandSegments(commandLine) where !segment.runsInBackground {
            let commandArguments = remoteCommandArguments(from: segment.arguments)
            guard let commandName = commandArguments.first.map(executableName) else { continue }

            switch commandName {
            case "ssh":
                if let session = parseSSHCommandLine(commandArguments) {
                    return .ssh(session)
                }
                continue
            case "mosh":
                return .mosh(destination: parseMoshCommandLine(commandArguments))
            case "mosh-client":
                return .mosh(destination: nil)
            default:
                continue
            }
        }
        return nil
    }

    private static let psPath = "/bin/ps"
    private static let noArgumentFlags = Set("46AaCfGgKkMNnqsTtVvXxYy")
    private static let valueArgumentFlags = Set("BbcDEeFIiJLlmOopQRSWw")
    private static let remoteDisplayExecutableNames: Set<String> = [
        "ssh",
        "mosh",
        "mosh-client",
    ]
    private static let moshLongOptionsWithValue: Set<String> = [
        "bind-server",
        "client",
        "family",
        "predict",
        "port",
        "server",
        "ssh",
    ]

    private static func normalizedTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let lastComponent = trimmed.split(separator: "/").last {
            return String(lastComponent)
        }
        return trimmed
    }

    private static func isForegroundRemoteProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        isForegroundProcess(process, ttyName: ttyName) &&
            remoteDisplayExecutableNames.contains(process.executableName)
    }

    private static func isForegroundRemoteShellProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        isForegroundProcess(process, ttyName: ttyName) &&
            RemoteShellTransport(executableName: process.executableName) != nil
    }

    private static func isForegroundProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizedTTYName(process.tty) == normalizedTTYName(ttyName) &&
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

        let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: pipe.fileHandleForReading)
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

    private struct ShellCommandSegment: Equatable {
        let arguments: [String]
        let runsInBackground: Bool
    }

    private static func shellCommandSegments(_ commandLine: String) -> [ShellCommandSegment] {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var segments: [ShellCommandSegment] = []
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var index = trimmed.startIndex

        func flushCurrent() {
            if !current.isEmpty {
                arguments.append(current)
                current = ""
            }
        }

        func flushSegment(runsInBackground: Bool) {
            flushCurrent()
            if !arguments.isEmpty {
                segments.append(ShellCommandSegment(arguments: arguments, runsInBackground: runsInBackground))
                arguments = []
            }
        }

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                    index = trimmed.index(after: index)
                    continue
                }
                if activeQuote == "\"" && character == "\\" {
                    let nextIndex = trimmed.index(after: index)
                    if nextIndex < trimmed.endIndex {
                        current.append(trimmed[nextIndex])
                        index = trimmed.index(after: nextIndex)
                        continue
                    }
                }
                current.append(character)
                index = trimmed.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index = trimmed.index(after: index)
                continue
            }
            if character == "\\" {
                let nextIndex = trimmed.index(after: index)
                if nextIndex < trimmed.endIndex {
                    current.append(trimmed[nextIndex])
                    index = trimmed.index(after: nextIndex)
                    continue
                }
            }
            let nextIndex = trimmed.index(after: index)
            if character == "&",
               current.last == ">" || current.last == "<" || (nextIndex < trimmed.endIndex && trimmed[nextIndex] == ">") {
                current.append(character)
                index = nextIndex
                continue
            }
            if character == ";" || character == "|" || character == "&" {
                let isDoubleSeparator = nextIndex < trimmed.endIndex && trimmed[nextIndex] == character
                flushSegment(runsInBackground: character == "&" && !isDoubleSeparator)
                index = isDoubleSeparator ? trimmed.index(after: nextIndex) : nextIndex
                continue
            }
            if character.isWhitespace {
                flushCurrent()
                index = trimmed.index(after: index)
                continue
            }

            current.append(character)
            index = trimmed.index(after: index)
        }

        flushSegment(runsInBackground: false)
        return segments
    }

    private static func remoteCommandArguments(from arguments: [String]) -> [String] {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let name = executableName(argument)
            if name == "command" || name == "exec" || name == "noglob" {
                index += 1
                continue
            }
            if isEnvironmentAssignment(argument) {
                index += 1
                continue
            }
            break
        }
        guard index < arguments.count else { return [] }
        return Array(arguments[index...])
    }

    private static func isEnvironmentAssignment(_ argument: String) -> Bool {
        guard let equalsIndex = argument.firstIndex(of: "="),
              equalsIndex != argument.startIndex,
              !argument.hasPrefix("-") else {
            return false
        }
        let name = argument[..<equalsIndex]
        return name.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    private static func executableName(_ argument: String) -> String {
        argument
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func parseCommandLine(
        _ arguments: [String],
        for transport: RemoteShellTransport
    ) -> DetectedSSHSession? {
        switch transport {
        case .ssh:
            return parseSSHCommandLine(arguments)
        case .eternalTerminal:
            return RemoteShellSessionParsing.parseEternalTerminalCommandLine(arguments)
        }
    }

    private static func parseSSHCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if RemoteShellSessionParsing.normalizedExecutableName(arguments[0]) == RemoteShellTransport.ssh.executableName {
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
        var isInteractiveSessionCandidate = true
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
            case "O", "W":
                isInteractiveSessionCandidate = false
                return true
            case "o":
                return RemoteShellSessionParsing.consumeSSHOption(
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
                case "G", "V":
                    isInteractiveSessionCandidate = false
                default:
                    break
                }
            }
            index += 1
        }

        guard isInteractiveSessionCandidate else { return nil }
        guard let destination else { return nil }
        let finalDestination = RemoteShellSessionParsing.resolveDestination(destination, loginName: loginName)
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

    private static func parseMoshCommandLine(_ arguments: [String]) -> String? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if RemoteShellSessionParsing.normalizedExecutableName(arguments[0]) == "mosh" {
            index = 1
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                return index < arguments.count ? normalizedMoshDestination(arguments[index]) : nil
            }
            if !argument.hasPrefix("-") || argument == "-" {
                return normalizedMoshDestination(argument)
            }

            if argument.hasPrefix("--") {
                let optionText = String(argument.dropFirst(2))
                let optionName = optionText
                    .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init)?
                    .lowercased() ?? ""
                if !optionText.contains("="), moshLongOptionsWithValue.contains(optionName) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if argument == "-p" {
                index += 2
                continue
            }
            if argument.hasPrefix("-p"), argument.count > 2 {
                index += 1
                continue
            }

            index += 1
        }

        return nil
    }

    private static func normalizedMoshDestination(_ destination: String) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - SSH/process execution and orphan cleanup
extension WorkspaceRemoteSessionController {
    func sshCommonArguments(batchMode: Bool, dropControlPath: Bool = false) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions, dropControlPath: dropControlPath)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    func backgroundSSHOptions(_ options: [String], dropControlPath: Bool = false) -> [String] {
        var batchSSHControlOptionKeys: Set<String> = [
            "controlmaster",
            "controlpersist",
        ]
        if dropControlPath {
            batchSSHControlOptionKeys.insert("controlpath")
        }
        return normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            stdin: stdin,
            timeout: timeout
        )
    }

    func scpExec(
        arguments: [String],
        timeout: TimeInterval = 30,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            stdin: nil,
            timeout: timeout,
            operation: operation
        )
    }

    func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
#if DEBUG
        if let override = Self.runProcessOverrideForTesting {
            let result = try override(executable, arguments, stdin, timeout)
            return CommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
        }
#endif

        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "cmux.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        var stdoutReadError: Error?
        var stderrReadError: Error?
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { captureGroup.leave() }
            let result = Self.readProcessPipeToEnd(stdoutHandle)
            captureQueue.sync {
                stdoutData = result.data
                stdoutReadError = result.readError
            }
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { captureGroup.leave() }
            let result = Self.readProcessPipeToEnd(stderrHandle)
            captureQueue.sync {
                stderrData = result.data
                stderrReadError = result.readError
            }
        }
#if DEBUG
        Self.runProcessReadHandlesDidInstallForTesting?(stdoutHandle, stderrHandle)
#endif

        var didFinishCapture = false
        func finishCaptureAndCloseReadHandles() {
            guard !didFinishCapture else { return }
            didFinishCapture = true
            captureGroup.wait()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if let stdoutReadError {
                debugLog(
                    "remote.proc.stdoutReadError exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                    "error=\(stdoutReadError.localizedDescription)"
                )
            }
            if let stderrReadError {
                debugLog(
                    "remote.proc.stderrReadError exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                    "error=\(stderrReadError.localizedDescription)"
                )
            }
        }

        do {
            try operation?.throwIfCancelled()
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            finishCaptureAndCloseReadHandles()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                finishCaptureAndCloseReadHandles()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            finishCaptureAndCloseReadHandles()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        finishCaptureAndCloseReadHandles()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(Self.debugLogSnippet(stdout)) " +
            "stderr=\(Self.debugLogSnippet(stderr))"
        )
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func readProcessPipeToEnd(_ fileHandle: FileHandle) -> ProcessPipeEndRead {
        ProcessPipeReader.readDataToEndOfFile(from: fileHandle)
    }

#if DEBUG
    func runProcessForTesting(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try runProcess(
            executable: executable,
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }
#endif

    static func orphanedCMUXRemoteSSHPIDs(
        psOutput: String,
        destination: String,
        relayPort: Int? = nil,
        persistentDaemonSlot: String? = nil
    ) -> [Int] {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return [] }
        let trimmedPersistentDaemonSlot = persistentDaemonSlot

        return psOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Int? in
                guard let parsed = parsePSLine(line) else { return nil }
                guard parsed.ppid == 1 else { return nil }
                guard isOrphanedCMUXRemoteSSHCommand(
                    parsed.command,
                    destination: trimmedDestination,
                    relayPort: relayPort,
                    persistentDaemonSlot: trimmedPersistentDaemonSlot
                ) else {
                    return nil
                }
                return parsed.pid
            }
            .sorted()
    }

    static func killOrphanedRemoteSSHProcesses(
        destination: String,
        relayPort: Int? = nil,
        persistentDaemonSlot: String? = nil
    ) {
        guard let output = captureCommandStandardOutput(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        ) else {
            return
        }

        for pid in orphanedCMUXRemoteSSHPIDs(
            psOutput: output,
            destination: destination,
            relayPort: relayPort,
            persistentDaemonSlot: persistentDaemonSlot
        ) {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
    }

    private static func captureCommandStandardOutput(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let outputData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdoutPipe.fileHandleForReading)
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: outputData, encoding: .utf8),
                  !output.isEmpty else {
                return nil
            }
            return output
        } catch {
            // Best effort cleanup only.
            return nil
        }
    }

    private static func parsePSLine(_ line: Substring) -> (pid: Int, ppid: Int, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let scanner = Scanner(string: trimmed)
        var pidValue: Int = 0
        var ppidValue: Int = 0
        guard scanner.scanInt(&pidValue), scanner.scanInt(&ppidValue) else {
            return nil
        }

        let commandStart = scanner.currentIndex
        let command = String(trimmed[commandStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return (pidValue, ppidValue, command)
    }

    private static func isOrphanedCMUXRemoteSSHCommand(
        _ command: String,
        destination: String,
        relayPort: Int?,
        persistentDaemonSlot: String?
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasPrefix("/usr/bin/ssh ") || trimmed.hasPrefix("ssh ") else { return false }
        guard commandContainsDestination(trimmed, destination: destination) else { return false }
        let trimmedPersistentDaemonSlot: String? = {
            guard let persistentDaemonSlot else { return nil }
            let trimmed = persistentDaemonSlot.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        if let relayPort {
            if trimmed.contains(" -N ")
                && trimmed.contains(" -R 127.0.0.1:\(relayPort):127.0.0.1:") {
                return true
            }
            guard let trimmedPersistentDaemonSlot else { return false }
            return isCMUXRemotePersistentDaemonServeStdioCommand(
                trimmed,
                slot: trimmedPersistentDaemonSlot
            )
        }

        if trimmed.contains(" -N ") && trimmed.contains(" -R 127.0.0.1:") {
            return true
        }
        if let trimmedPersistentDaemonSlot {
            if isCMUXRemotePersistentDaemonServeStdioCommand(
                trimmed,
                slot: trimmedPersistentDaemonSlot
            ) {
                return true
            }
            return isCMUXRemoteNonPersistentDaemonServeStdioCommand(trimmed)
        }
        if isCMUXRemoteDaemonServeStdioCommand(trimmed) {
            return true
        }
        return false
    }

    private static func isCMUXRemoteDaemonServeStdioCommand(_ command: String) -> Bool {
        guard command.contains("cmuxd-remote") else { return false }
        let normalized = command
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        return normalized.contains(" serve ") && normalized.contains(" --stdio")
    }

    private static func isCMUXRemoteNonPersistentDaemonServeStdioCommand(_ command: String) -> Bool {
        guard isCMUXRemoteDaemonServeStdioCommand(command) else { return false }
        let normalized = command
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        return !normalized.contains(" --persistent")
    }

    private static func isCMUXRemotePersistentDaemonServeStdioCommand(
        _ command: String,
        slot: String
    ) -> Bool {
        guard isCMUXRemoteDaemonServeStdioCommand(command) else { return false }
        let normalized = command
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
        guard normalized.contains(" --persistent") else { return false }
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for index in tokens.indices {
            let token = tokens[index]
            if token == "--slot" {
                return nextNonShellEscapeToken(after: index, in: tokens) == slot
            }
            if token.hasPrefix("--slot=") {
                let slotValue = String(token.dropFirst("--slot=".count))
                if !slotValue.isEmpty {
                    return slotValue == slot
                }
                return nextNonShellEscapeToken(after: index, in: tokens) == slot
            }
        }
        return false
    }

    private static func nextNonShellEscapeToken(after index: Int, in tokens: [String]) -> String? {
        var nextIndex = index + 1
        while tokens.indices.contains(nextIndex) {
            let token = tokens[nextIndex]
            if !isShellEscapeNoiseToken(token) {
                return token
            }
            nextIndex += 1
        }
        return nil
    }

    private static func isShellEscapeNoiseToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0 == "\\" }
    }

    private static func commandContainsDestination(_ command: String, destination: String) -> Bool {
        guard !destination.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: destination)
        guard let regex = try? NSRegularExpression(
            pattern: "(^|[\\s'\\\"])\(escaped)($|[\\s'\\\"])",
            options: []
        ) else {
            return command.contains(destination)
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    static func executableSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pathHelperOutput: String? = nil
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendSearchPath(_ rawPath: String?) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                appendSearchPath(String(component))
            }
        }

        if let home = environment["HOME"], !home.isEmpty {
            appendSearchPath((home as NSString).appendingPathComponent(".local/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("go/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("bin"))
        }

        let helperOutput = pathHelperOutput ?? pathHelperShellOutput()
        for component in parsePathHelperPaths(helperOutput) {
            appendSearchPath(component)
        }

        for component in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] {
            appendSearchPath(component)
        }

        return ordered
    }

    static func parsePathHelperPaths(_ output: String) -> [String] {
        for fragment in output.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("PATH=\"") else { continue }
            let suffix = trimmed.dropFirst("PATH=\"".count)
            guard let closingQuote = suffix.firstIndex(of: "\"") else { return [] }
            return suffix[..<closingQuote]
                .split(separator: ":")
                .map(String.init)
        }
        return []
    }

    private static func pathHelperShellOutput() -> String {
        let executable = "/usr/libexec/path_helper"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdout.fileHandleForReading)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func which(_ executable: String) -> String? {
        for component in executableSearchPaths() {
            let candidate = (component as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["CMUX_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

}

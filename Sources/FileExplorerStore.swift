import AppKit
import Combine
import Darwin
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Explorer Visual Style

enum FileExplorerStyle: Int, CaseIterable {
    case liquidGlass = 0
    case highDensity = 1
    case terminalStealth = 2
    case proStudio = 3
    case finder = 4

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .highDensity: return "High-Density IDE"
        case .terminalStealth: return "Terminal Stealth"
        case .proStudio: return "Pro Studio"
        case .finder: return "Finder"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .liquidGlass: return 28
        case .highDensity: return 20
        case .terminalStealth: return 24
        case .proStudio: return 32
        case .finder: return 26
        }
    }

    var indentation: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 12
        case .terminalStealth: return 14
        case .proStudio: return 20
        case .finder: return 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 14
        case .terminalStealth: return 12
        case .proStudio: return 18
        case .finder: return 18
        }
    }

    var iconWeight: NSFont.Weight {
        switch self {
        case .liquidGlass: return .regular
        case .highDensity: return .regular
        case .terminalStealth: return .light
        case .proStudio: return .regular
        case .finder: return .medium
        }
    }

    var nameFont: NSFont {
        switch self {
        case .liquidGlass: return .systemFont(ofSize: 13, weight: .medium)
        case .highDensity: return .systemFont(ofSize: 11, weight: .regular)
        case .terminalStealth: return .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .proStudio: return .systemFont(ofSize: 14, weight: .semibold)
        case .finder: return .systemFont(ofSize: 13, weight: .regular)
        }
    }

    var iconToTextSpacing: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 4
        case .terminalStealth: return 6
        case .proStudio: return 12
        case .finder: return 6
        }
    }

    var selectionInset: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 4
        case .finder: return 4
        }
    }

    var selectionRadius: CGFloat {
        switch self {
        case .liquidGlass: return 6
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 8
        case .finder: return 5
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .liquidGlass: return .controlAccentColor.withAlphaComponent(0.15)
        case .highDensity: return .selectedContentBackgroundColor
        case .terminalStealth: return .controlAccentColor
        case .proStudio: return .controlAccentColor
        case .finder: return .controlAccentColor.withAlphaComponent(0.15)
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .liquidGlass: return .labelColor.withAlphaComponent(0.05)
        case .highDensity: return .white.withAlphaComponent(0.05)
        case .terminalStealth: return .white.withAlphaComponent(0.03)
        case .proStudio: return .white.withAlphaComponent(0.1)
        case .finder: return .labelColor.withAlphaComponent(0.04)
        }
    }

    var usesBorderSelection: Bool {
        self == .terminalStealth
    }

    var fileIconTint: NSColor {
        switch self {
        case .liquidGlass: return .secondaryLabelColor
        case .highDensity: return .secondaryLabelColor
        case .terminalStealth: return .tertiaryLabelColor
        case .proStudio: return .secondaryLabelColor
        case .finder: return NSColor(white: 0.55, alpha: 1.0)
        }
    }

    var folderIconTint: NSColor {
        switch self {
        case .liquidGlass: return .systemBlue
        case .highDensity: return .secondaryLabelColor
        case .terminalStealth: return .tertiaryLabelColor
        case .proStudio: return .systemBlue
        case .finder: return .systemBlue
        }
    }

    func gitColor(for status: GitFileStatus) -> NSColor {
        switch self {
        case .liquidGlass:
            switch status {
            case .modified: return .systemOrange
            case .added: return .systemTeal
            case .deleted: return .systemRed
            case .renamed: return .systemPurple
            case .untracked: return .quaternaryLabelColor
            }
        case .highDensity:
            switch status {
            case .modified: return .systemYellow
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .renamed: return .systemBlue
            case .untracked: return .tertiaryLabelColor
            }
        case .terminalStealth:
            switch status {
            case .modified: return NSColor(red: 0.8, green: 0.7, blue: 0.4, alpha: 1.0)
            case .added: return NSColor(red: 0.5, green: 0.8, blue: 0.5, alpha: 1.0)
            case .deleted: return NSColor(red: 0.8, green: 0.4, blue: 0.4, alpha: 1.0)
            case .renamed: return NSColor(red: 0.5, green: 0.7, blue: 0.9, alpha: 1.0)
            case .untracked: return NSColor(white: 0.5, alpha: 1.0)
            }
        case .proStudio:
            switch status {
            case .modified: return .systemYellow
            case .added: return .systemGreen
            case .deleted: return .systemPink
            case .renamed: return .systemCyan
            case .untracked: return .systemGray
            }
        case .finder:
            switch status {
            case .modified: return .systemOrange
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .renamed: return .systemBlue
            case .untracked: return .tertiaryLabelColor
            }
        }
    }

    static var current: FileExplorerStyle {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "fileExplorer.style") == nil {
            return .highDensity
        }
        return FileExplorerStyle(rawValue: defaults.integer(forKey: "fileExplorer.style")) ?? .highDensity
    }
}

// MARK: - Models

struct FileExplorerEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
}

final class FileExplorerNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileExplorerNode]?
    var isLoading: Bool = false
    var error: String?

    init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    var isExpandable: Bool { isDirectory }

    var sortedChildren: [FileExplorerNode]? {
        children?.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Root Resolver

enum FileExplorerRootResolver {
    static func displayPath(for fullPath: String, homePath: String?) -> String {
        guard let home = homePath, !home.isEmpty else { return fullPath }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normalizedPath = fullPath.hasSuffix("/") ? String(fullPath.dropLast()) : fullPath
        if normalizedPath == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            return "~/" + normalizedPath.dropFirst(homePrefix.count)
        }
        return fullPath
    }
}

// MARK: - Provider Protocol

protocol FileExplorerProvider: AnyObject {
    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry]
    var homePath: String { get }
    var isAvailable: Bool { get }
}

struct SSHFileExplorerConnection: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
}

protocol SSHFileExplorerTransport: AnyObject {
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String
    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry]
    nonisolated func download(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        toLocalDirectory localDirectory: String
    ) async throws -> String
}

enum FileExplorerWorkspaceRoot: Equatable {
    case none
    case local(path: String)
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        isAvailable: Bool,
        unavailableDetail: String?
    )
}

// MARK: - Local Provider

final class LocalFileExplorerProvider: FileExplorerProvider {
    var homePath: String { NSHomeDirectory() }
    var isAvailable: Bool { true }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)
        return contents.compactMap { name in
            guard showHidden || !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileExplorerEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
        }
    }
}

// MARK: - SSH Provider

// Captured by async SSH tasks; mutable availability/root state is guarded by stateLock.
final class SSHFileExplorerProvider: FileExplorerProvider, @unchecked Sendable {
    private struct State: Sendable {
        var homePath: String
        var isAvailable: Bool
    }

    let connection: SSHFileExplorerConnection
    let displayTarget: String
    private let transport: SSHFileExplorerTransport
    private let stateLock = NSLock()
    private var state: State

    var homePath: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.homePath
    }

    var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.isAvailable
    }

    var destination: String { connection.destination }
    var port: Int? { connection.port }
    var identityFile: String? { connection.identityFile }
    var sshOptions: [String] { connection.sshOptions }

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        displayTarget: String? = nil,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = SSHFileExplorerConnection(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions
        )
        self.displayTarget = displayTarget ?? {
            guard let port else { return destination }
            return "\(destination):\(port)"
        }()
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    init(
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = connection
        self.displayTarget = displayTarget
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    func updateAvailability(_ available: Bool, homePath: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.isAvailable = available
        if let homePath {
            state.homePath = homePath
        }
    }

    func resolveHomePath() async throws -> String {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        let home = try await transport.resolveHomePath(connection: connection)
        guard !home.isEmpty else {
            throw FileExplorerError.sshCommandFailed("remote HOME was empty")
        }
        return home
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        return try await transport.listDirectory(path: path, connection: connection, showHidden: showHidden)
    }

    func download(remotePath: String, isDirectory: Bool, toLocalDirectory localDirectory: String) async throws -> String {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        return try await transport.download(
            remotePath: remotePath,
            isDirectory: isDirectory,
            connection: connection,
            toLocalDirectory: localDirectory
        )
    }
}

final class ProcessSSHFileExplorerTransport: SSHFileExplorerTransport {
    static let shared = ProcessSSHFileExplorerTransport()

    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: #"printf '%s\n' "$HOME""#
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        try await Self.runSSHListCommand(path: path, connection: connection, showHidden: showHidden)
    }

    nonisolated func download(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        toLocalDirectory localDirectory: String
    ) async throws -> String {
        try await Self.runSCPDownloadCommand(
            remotePath: remotePath,
            isDirectory: isDirectory,
            connection: connection,
            localDirectory: localDirectory
        )
    }

    private struct SSHCommandResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    // Keeps the child process reachable from the cancellation handler while
    // stdout/stderr are drained concurrently with process execution.
    private final class CommandProcess: @unchecked Sendable {
        private final class OutputCollector: @unchecked Sendable {
            private enum Stream {
                case stdout
                case stderr
            }

            private let stdoutHandle: FileHandle
            private let stderrHandle: FileHandle
            private let lock = NSLock()
            private var stdout = Data()
            private var stderr = Data()
            private var isFinished = false

            init(stdout: Pipe, stderr: Pipe) {
                stdoutHandle = stdout.fileHandleForReading
                stderrHandle = stderr.fileHandleForReading
            }

            func start() {
                stdoutHandle.readabilityHandler = { [weak self] handle in
                    self?.appendAvailableData(from: handle, to: .stdout)
                }
                stderrHandle.readabilityHandler = { [weak self] handle in
                    self?.appendAvailableData(from: handle, to: .stderr)
                }
            }

            func finish() -> (stdout: String, stderr: String) {
                lock.lock()
                guard !isFinished else {
                    let output = outputLocked()
                    lock.unlock()
                    return output
                }
                isFinished = true
                lock.unlock()

                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                append(stdoutHandle.readDataToEndOfFile(), to: .stdout)
                append(stderrHandle.readDataToEndOfFile(), to: .stderr)

                lock.lock()
                let output = outputLocked()
                lock.unlock()
                return output
            }

            func cancel() {
                lock.lock()
                guard !isFinished else {
                    lock.unlock()
                    return
                }
                isFinished = true
                lock.unlock()

                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
            }

            private func appendAvailableData(from handle: FileHandle, to stream: Stream) {
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                append(data, to: stream)
            }

            private func append(_ data: Data, to stream: Stream) {
                guard !data.isEmpty else { return }
                lock.lock()
                defer { lock.unlock() }
                switch stream {
                case .stdout:
                    stdout.append(data)
                case .stderr:
                    stderr.append(data)
                }
            }

            private func outputLocked() -> (stdout: String, stderr: String) {
                (
                    String(data: stdout, encoding: .utf8) ?? "",
                    String(data: stderr, encoding: .utf8) ?? ""
                )
            }
        }

        private final class TerminationWaiter: @unchecked Sendable {
            private let lock = NSLock()
            private var status: Int32?
            private var continuation: CheckedContinuation<Int32, Never>?

            func wait() async -> Int32 {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if let status {
                        lock.unlock()
                        continuation.resume(returning: status)
                        return
                    }
                    self.continuation = continuation
                    lock.unlock()
                }
            }

            func finish(status: Int32) {
                lock.lock()
                if let continuation {
                    self.continuation = nil
                    lock.unlock()
                    continuation.resume(returning: status)
                    return
                }
                self.status = status
                lock.unlock()
            }
        }

        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private var cancelled = false
        private var started = false
        private var timedOut = false

        init(executable: String, arguments: [String]) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run(timeout: TimeInterval? = nil) async throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            let outputCollector = OutputCollector(stdout: outPipe, stderr: errPipe)
            let terminationWaiter = TerminationWaiter()
            process.terminationHandler = { terminatedProcess in
                terminationWaiter.finish(status: terminatedProcess.terminationStatus)
            }
            outputCollector.start()

            do {
                try process.run()
            } catch {
                outputCollector.cancel()
                process.terminationHandler = nil
                throw error
            }

            lock.lock()
            started = true
            let shouldTerminate = cancelled && process.isRunning
            lock.unlock()
            if shouldTerminate {
                process.terminate()
            }

            let terminationStatus: Int32
            do {
                terminationStatus = try await waitForTermination(timeout: timeout, waiter: terminationWaiter)
            } catch {
                terminate()
                forceKillIfRunning()
                _ = await terminationWaiter.wait()
                _ = outputCollector.finish()
                process.terminationHandler = nil
                throw error
            }
            let output = outputCollector.finish()
            process.terminationHandler = nil
            try Task.checkCancellation()
            if hasTimedOut {
                throw FileExplorerError.downloadTimedOut
            }

            return SSHCommandResult(
                stdout: output.stdout,
                stderr: output.stderr,
                terminationStatus: terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let shouldTerminate = started && process.isRunning
            lock.unlock()

            if shouldTerminate {
                process.terminate()
            }
        }

        private var hasTimedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        private func markTimedOutAndTerminate() {
            lock.lock()
            timedOut = true
            let shouldTerminate = started && process.isRunning
            lock.unlock()

            if shouldTerminate {
                process.terminate()
            }
        }

        private func forceKillIfRunning() {
            lock.lock()
            let shouldKill = started && process.isRunning
            let processIdentifier = process.processIdentifier
            lock.unlock()

            if shouldKill {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        private func waitForTermination(timeout: TimeInterval?, waiter: TerminationWaiter) async throws -> Int32 {
            guard let timeout else {
                let status = await waiter.wait()
                if hasTimedOut {
                    throw FileExplorerError.downloadTimedOut
                }
                return status
            }

            let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            return try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { [self, waiter] in
                    let status = await waiter.wait()
                    if hasTimedOut {
                        throw FileExplorerError.downloadTimedOut
                    }
                    return status
                }
                group.addTask { [self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        terminate()
                        forceKillIfRunning()
                        throw error
                    }
                    markTimedOutAndTerminate()
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        forceKillIfRunning()
                        throw error
                    }
                    forceKillIfRunning()
                    throw FileExplorerError.downloadTimedOut
                }

                do {
                    guard let status = try await group.next() else {
                        throw FileExplorerError.downloadTimedOut
                    }
                    group.cancelAll()
                    return status
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }
    }

    private static func runSSHCommand(connection: SSHFileExplorerConnection, command: String) async throws -> String {
        let commandProcess = CommandProcess(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(connection: connection, command: command)
        )
        let result = try await withTaskCancellationHandler {
            try await commandProcess.run()
        } onCancel: {
            commandProcess.terminate()
        }

        guard result.terminationStatus == 0 else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        return result.stdout
    }

    private static func runSCPCommand(arguments: [String], timeout: TimeInterval) async throws -> SSHCommandResult {
        let commandProcess = CommandProcess(executable: "/usr/bin/scp", arguments: arguments)
        return try await withTaskCancellationHandler {
            try await commandProcess.run(timeout: timeout)
        } onCancel: {
            commandProcess.terminate()
        }
    }

    private static func sshArguments(connection: SSHFileExplorerConnection, command: String) -> [String] {
        var args: [String] = []
        if let port = connection.port {
            args += ["-p", String(port)]
        }
        if let identityFile = connection.identityFile {
            args += ["-i", identityFile]
        }
        for option in connection.sshOptions {
            args += ["-o", option]
        }
        // Batch mode, no TTY, connection timeout
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [connection.destination, command]
        return args
    }

    private static func runSSHListCommand(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        // Escape single quotes in path for shell safety
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        let output = try await runSSHCommand(
            connection: connection,
            command: "ls \(lsFlags) '\(escapedPath)' 2>/dev/null"
        )

        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let entry = String(line)
            // Skip . and .. entries
            guard entry != "./" && entry != "../" else { return nil }
            let isDir = entry.hasSuffix("/")
            let name = isDir ? String(entry.dropLast()) : entry
            guard showHidden || !name.hasPrefix(".") else { return nil }
            // Strip type indicators from -F flag (*, @, =, |) for files
            let cleanName: String
            if !isDir, let last = name.last, "*@=|".contains(last) {
                cleanName = String(name.dropLast())
            } else {
                cleanName = name
            }
            let fullPath = normalizedPath + cleanName
            return FileExplorerEntry(name: cleanName, path: fullPath, isDirectory: isDir)
        }
    }

    private static func runSCPDownloadCommand(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        localDirectory: String
    ) async throws -> String {
        let normalizedDirectory = (localDirectory as NSString).expandingTildeInPath
        var isLocalDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedDirectory, isDirectory: &isLocalDirectory),
              isLocalDirectory.boolValue else {
            throw FileExplorerError.invalidDownloadDestination(normalizedDirectory)
        }

        let targetName = (remotePath as NSString).lastPathComponent
        let targetPath = (normalizedDirectory as NSString).appendingPathComponent(
            targetName.isEmpty ? "download" : targetName
        )
        let args = scpDownloadArguments(
            remotePath: remotePath,
            isDirectory: isDirectory,
            connection: connection,
            localDirectory: normalizedDirectory
        )
        let result = try await runSCPCommand(arguments: args, timeout: 30 * 60)
        guard result.terminationStatus == 0 else {
            let detail = bestErrorLine(stderr: result.stderr, stdout: result.stdout) ??
                "scp exited \(result.terminationStatus)"
            throw FileExplorerError.downloadFailed(detail)
        }
        return targetPath
    }

    private static func scpDownloadArguments(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        localDirectory: String
    ) -> [String] {
        var args: [String] = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if isDirectory {
            args.append("-r")
        }
        if let port = connection.port {
            args += ["-P", String(port)]
        }
        if let identityFile = connection.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        let effectiveSSHOptions = backgroundSSHOptions(connection.sshOptions)
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }

        args += [
            "\(scpRemoteDestination(connection.destination)):\(shellSingleQuoted(remotePath))",
            localDirectory,
        ]
        return args
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

    private static func backgroundSSHOptions(_ options: [String]) -> [String] {
        let batchSSHControlOptionKeys: Set<String> = [
            "controlmaster",
            "controlpersist",
        ]
        return normalizedSSHOptions(options).filter { option in
            guard let key = optionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
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
    static func scpDownloadArgumentsForTesting(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        localDirectory: String
    ) -> [String] {
        scpDownloadArguments(
            remotePath: remotePath,
            isDirectory: isDirectory,
            connection: connection,
            localDirectory: localDirectory
        )
    }
#endif
}

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)
    case invalidDownloadDestination(String)
    case downloadFailed(String)
    case downloadTimedOut

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed(let detail):
            return String(
                format: String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed: %@"),
                detail
            )
        case .invalidDownloadDestination(let path):
            return String(
                format: String(
                    localized: "fileExplorer.error.downloadDestinationInvalid",
                    defaultValue: "Download destination is not a local folder: %@"
                ),
                path
            )
        case .downloadFailed(let detail):
            return String(
                format: String(localized: "fileExplorer.error.downloadFailed", defaultValue: "Download failed: %@"),
                detail
            )
        case .downloadTimedOut:
            return String(localized: "fileExplorer.error.downloadTimedOut", defaultValue: "Download timed out.")
        }
    }
}

// MARK: - Selection Restoration

enum FileExplorerSelectionRestoration {
    static func scrollRow(anchorRow: Int?, exactRows: IndexSet) -> Int? {
        if let anchorRow, exactRows.contains(anchorRow) {
            return anchorRow
        }
        return exactRows.first
    }
}

// MARK: - Store

/// All access must happen on the main thread. Properties are not marked @MainActor
/// because NSOutlineView data source/delegate methods are called on the main thread
/// but are not annotated @MainActor.
final class FileExplorerStore: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileExplorerNode] = []
    @Published private(set) var isRootLoading: Bool = false
    @Published private(set) var gitStatusByPath: [String: GitFileStatus] = [:]
    @Published private(set) var contentRevision = 0
    @Published private(set) var rootStatusMessage: String?

    var provider: FileExplorerProvider?

    /// Whether hidden files are shown. Set from FileExplorerState externally.
    var showHiddenFiles: Bool = false

    private(set) var defaultLocalDownloadDirectory: String?

    /// Watches the root directory for filesystem changes (local only).
    private var directoryWatcher: FileExplorerDirectoryWatcher?

    /// Paths that are logically expanded (persisted across provider changes)
    private(set) var expandedPaths: Set<String> = []

    /// Stable navigation selection. The outline view mirrors this path after reloads.
    private(set) var selectedPath: String?

    /// Stable multi-selection. `selectedPath` remains the keyboard/navigation anchor.
    private(set) var selectedPaths: Set<String> = []

    /// Folder path whose first child should be selected once its async load completes.
    private var pendingDescendIntoFirstChildPath: String?

    /// Paths currently being loaded
    private(set) var loadingPaths: Set<String> = []

    /// In-flight load tasks keyed by path
    private var loadTasks: [String: Task<Void, Never>] = [:]

    /// Cache of path -> node for quick lookup
    private var nodesByPath: [String: FileExplorerNode] = [:]

    /// Prefetch debounce: path -> work item
    private var prefetchWorkItems: [String: DispatchWorkItem] = [:]

    private var remoteHomeResolutionTask: Task<Void, Never>?
    private var remoteHomeResolutionKey: String?

    var displayRootPath: String {
        if let sshProvider = provider as? SSHFileExplorerProvider {
            guard !rootPath.isEmpty else {
                return "ssh://\(sshProvider.displayTarget)"
            }
            return "ssh://\(sshProvider.displayTarget):\(rootPath)"
        }
        return FileExplorerRootResolver.displayPath(for: rootPath, homePath: provider?.homePath)
    }

    // MARK: - Public API

    func applyWorkspaceRoot(
        _ request: FileExplorerWorkspaceRoot,
        sshTransport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        switch request {
        case .none:
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            if provider != nil {
                setProvider(nil, reloadIfAvailable: false)
            }
            setRootPath("")

        case .local(let path):
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            if !(provider is LocalFileExplorerProvider) {
                setRootPath("")
                setProvider(LocalFileExplorerProvider(), reloadIfAvailable: false)
            }
            setRootPath(path)

        case .remoteSSH(let workspaceId, let connection, let displayTarget, let isAvailable, let unavailableDetail):
            applyRemoteSSHWorkspaceRoot(
                workspaceId: workspaceId,
                connection: connection,
                displayTarget: displayTarget,
                isAvailable: isAvailable,
                unavailableDetail: unavailableDetail,
                sshTransport: sshTransport
            )
        }
    }

    func setDefaultLocalDownloadDirectory(_ path: String?) {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            defaultLocalDownloadDirectory = nil
            return
        }
        let normalizedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            defaultLocalDownloadDirectory = nil
            return
        }
        defaultLocalDownloadDirectory = normalizedPath
    }

    func setRootPath(_ path: String) {
        guard path != rootPath else {
            #if DEBUG
            NSLog("[FileExplorer] setRootPath skipped (same path): \(path)")
            #endif
            return
        }
        #if DEBUG
        NSLog("[FileExplorer] setRootPath: \(rootPath) -> \(path)")
        #endif
        if let selectedPath, !Self.path(selectedPath, isContainedIn: path) {
            self.selectedPath = nil
            selectedPaths = []
            pendingDescendIntoFirstChildPath = nil
        }
        rootPath = path
        reload()
        refreshGitStatus()
        updateDirectoryWatcher()
    }

    func refreshGitStatus() {
        guard !rootPath.isEmpty else {
            gitStatusByPath = [:]
            return
        }
        let path = rootPath
        if let sshProvider = provider as? SSHFileExplorerProvider {
            let dest = sshProvider.destination
            let port = sshProvider.port
            let identity = sshProvider.identityFile
            let opts = sshProvider.sshOptions
            DispatchQueue.global(qos: .utility).async {
                let status = GitStatusProvider.fetchStatusSSH(
                    directory: path, destination: dest, port: port,
                    identityFile: identity, sshOptions: opts
                )
                DispatchQueue.main.async { [weak self] in
                    self?.gitStatusByPath = status
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                let status = GitStatusProvider.fetchStatus(directory: path)
                DispatchQueue.main.async { [weak self] in
                    self?.gitStatusByPath = status
                }
            }
        }
    }

    private func updateDirectoryWatcher() {
        if provider is LocalFileExplorerProvider, !rootPath.isEmpty {
            if directoryWatcher == nil {
                directoryWatcher = FileExplorerDirectoryWatcher { [weak self] in
                    self?.reload()
                    self?.refreshGitStatus()
                }
            }
            directoryWatcher?.watch(path: rootPath)
        } else {
            directoryWatcher?.stop()
        }
    }

    private func setProvider(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        #if DEBUG
        NSLog("[FileExplorer] setProvider: \(type(of: newProvider).self) available=\(newProvider?.isAvailable ?? false)")
        #endif
        provider = newProvider
        // Re-expand previously expanded nodes if provider becomes available
        if reloadIfAvailable, newProvider?.isAvailable == true {
            reload()
        }
    }

    #if DEBUG
    func setProviderForTesting(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        setProvider(newProvider, reloadIfAvailable: reloadIfAvailable)
    }
    #endif

    func reload() {
        #if DEBUG
        NSLog("[FileExplorer] reload() path=\(rootPath) provider=\(type(of: provider).self)")
        #endif
        contentRevision &+= 1
        cancelAllLoads()
        rootNodes = []
        nodesByPath = [:]
        guard !rootPath.isEmpty, provider != nil else { return }
        isRootLoading = true
        let path = rootPath
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadChildren(for: nil, at: path)
        }
        loadTasks[rootPath] = task
    }

    func expand(node: FileExplorerNode) {
        guard node.isDirectory else { return }
        expandedPaths.insert(node.path)
        if node.children == nil, loadTasks[node.path] == nil, !loadingPaths.contains(node.path) {
            node.isLoading = true
            node.error = nil
            objectWillChange.send()
            let nodePath = node.path
            let task = Task { [weak self] in
                guard let self else { return }
                await self.loadChildren(for: node, at: nodePath)
            }
            loadTasks[node.path] = task
        }
    }

    func collapse(node: FileExplorerNode) {
        expandedPaths.remove(node.path)
        if pendingDescendIntoFirstChildPath == node.path {
            pendingDescendIntoFirstChildPath = nil
        }
        objectWillChange.send()
    }

    func isExpanded(_ node: FileExplorerNode) -> Bool {
        expandedPaths.contains(node.path)
    }

    func select(node: FileExplorerNode?) {
        let path = node?.path
        let paths = path.map { Set([$0]) } ?? []
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func select(nodes: [FileExplorerNode], anchor: FileExplorerNode?) {
        let paths = Set(nodes.map(\.path))
        let path = anchor?.path ?? nodes.first?.path
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func requestDescendIntoFirstChild(of node: FileExplorerNode) {
        guard node.isDirectory else { return }
        selectedPath = node.path
        selectedPaths = [node.path]
        pendingDescendIntoFirstChildPath = node.path
        expand(node: node)
    }

    func prefetchChildren(for node: FileExplorerNode) {
        guard node.isDirectory, node.children == nil, !loadingPaths.contains(node.path) else { return }
        // Debounce: only prefetch if hover persists for 200ms
        let path = node.path
        prefetchWorkItems[path]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, node.children == nil, !self.loadingPaths.contains(path) else { return }
                // Silent prefetch: don't show loading indicator
                await self.loadChildren(for: node, at: path, silent: true)
            }
        }
        prefetchWorkItems[path] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func cancelPrefetch(for node: FileExplorerNode) {
        prefetchWorkItems[node.path]?.cancel()
        prefetchWorkItems.removeValue(forKey: node.path)
    }

    /// Called when SSH provider becomes available after being unavailable.
    /// Re-hydrates expanded nodes that were waiting.
    func hydrateExpandedNodes() {
        guard let provider, provider.isAvailable, !expandedPaths.isEmpty else { return }
        #if DEBUG
        NSLog("[FileExplorer] hydrateExpandedNodes: \(expandedPaths.count) paths to hydrate")
        #endif
        reload()
    }

    // MARK: - Private

    @MainActor
    private func loadChildren(for parentNode: FileExplorerNode?, at path: String, silent: Bool = false) async {
        guard let provider else { return }

        if !silent {
            loadingPaths.insert(path)
            parentNode?.error = nil
            objectWillChange.send()
        }

        do {
            let entries = try await provider.listDirectory(path: path, showHidden: showHiddenFiles)
            try Task.checkCancellation()
            let children = entries.map { entry in
                let node = FileExplorerNode(name: entry.name, path: entry.path, isDirectory: entry.isDirectory)
                nodesByPath[entry.path] = node
                return node
            }.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            if let parentNode {
                parentNode.children = children
                parentNode.isLoading = false
                parentNode.error = nil
                if pendingDescendIntoFirstChildPath == parentNode.path {
                    let path = children.first?.path ?? parentNode.path
                    selectedPath = path
                    selectedPaths = [path]
                    pendingDescendIntoFirstChildPath = nil
                }
            } else {
                rootNodes = children
                isRootLoading = false
                setRootStatusMessage(nil)
                if selectedPath == nil {
                    selectedPath = children.first?.path
                    selectedPaths = selectedPath.map { Set([$0]) } ?? []
                }
            }
            loadingPaths.remove(path)
            loadTasks.removeValue(forKey: path)
            objectWillChange.send()

            // Auto-expand children that were previously expanded
            for child in children where child.isDirectory && expandedPaths.contains(child.path) {
                child.isLoading = true
                objectWillChange.send()
                let childPath = child.path
                let childTask = Task { [weak self] in
                    guard let self else { return }
                    await self.loadChildren(for: child, at: childPath)
                }
                loadTasks[child.path] = childTask
            }
        } catch {
            if !Task.isCancelled {
                if let parentNode {
                    parentNode.isLoading = false
                    parentNode.error = error.localizedDescription
                } else {
                    isRootLoading = false
                    setRootStatusMessage(error.localizedDescription)
                }
                loadingPaths.remove(path)
                loadTasks.removeValue(forKey: path)
                objectWillChange.send()
            }
        }
    }

    private func cancelAllLoads() {
        for (_, task) in loadTasks {
            task.cancel()
        }
        loadTasks.removeAll()
        loadingPaths.removeAll()
        pendingDescendIntoFirstChildPath = nil
        for (_, item) in prefetchWorkItems {
            item.cancel()
        }
        prefetchWorkItems.removeAll()
        isRootLoading = false
    }

    private func applyRemoteSSHWorkspaceRoot(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        isAvailable: Bool,
        unavailableDetail: String?,
        sshTransport: SSHFileExplorerTransport
    ) {
        let existingProvider = provider as? SSHFileExplorerProvider
        let sshProvider: SSHFileExplorerProvider
        if let existingProvider,
           existingProvider.connection == connection,
           existingProvider.displayTarget == displayTarget {
            sshProvider = existingProvider
            sshProvider.updateAvailability(isAvailable, homePath: nil)
        } else {
            cancelRemoteHomeResolution()
            setRootPath("")
            sshProvider = SSHFileExplorerProvider(
                connection: connection,
                displayTarget: displayTarget,
                homePath: "",
                isAvailable: isAvailable,
                transport: sshTransport
            )
            setProvider(sshProvider, reloadIfAvailable: false)
        }

        guard isAvailable else {
            cancelRemoteHomeResolution()
            setRootPath("")
            let detail = unavailableDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                setRootStatusMessage(
                    String(
                        localized: "fileExplorer.status.sshUnavailableWithDetail",
                        defaultValue: "SSH files unavailable: \(detail)"
                    )
                )
            } else {
                setRootStatusMessage(
                    String(localized: "fileExplorer.status.sshUnavailable", defaultValue: "SSH files unavailable")
                )
            }
            return
        }

        let currentHomePath = sshProvider.homePath
        if !currentHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setRootStatusMessage(nil)
            setRootPath(currentHomePath)
            return
        }

        resolveRemoteHome(
            workspaceId: workspaceId,
            provider: sshProvider,
            connection: connection
        )
    }

    private func resolveRemoteHome(
        workspaceId: UUID,
        provider sshProvider: SSHFileExplorerProvider,
        connection: SSHFileExplorerConnection
    ) {
        let resolutionKey = [
            workspaceId.uuidString,
            connection.destination,
            connection.port.map(String.init) ?? "",
            connection.identityFile ?? "",
            connection.sshOptions.joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")

        guard remoteHomeResolutionKey != resolutionKey else { return }
        remoteHomeResolutionTask?.cancel()
        remoteHomeResolutionKey = resolutionKey
        setRootPath("")
        setRootStatusMessage(String(localized: "fileExplorer.status.sshResolvingHome", defaultValue: "Resolving remote home..."))

        remoteHomeResolutionTask = Task { [weak self, weak sshProvider] in
            guard let sshProvider else { return }
            do {
                let homePath = try await sshProvider.resolveHomePath()
                await MainActor.run { [weak self, weak sshProvider] in
                    guard let self,
                          let sshProvider,
                          self.remoteHomeResolutionKey == resolutionKey,
                          self.provider === sshProvider else { return }
                    self.remoteHomeResolutionKey = nil
                    self.remoteHomeResolutionTask = nil
                    sshProvider.updateAvailability(true, homePath: homePath)
                    self.setRootStatusMessage(nil)
                    self.setRootPath(homePath)
                }
            } catch {
                await MainActor.run { [weak self, weak sshProvider] in
                    guard let self,
                          let sshProvider,
                          self.remoteHomeResolutionKey == resolutionKey,
                          self.provider === sshProvider else { return }
                    self.remoteHomeResolutionKey = nil
                    self.remoteHomeResolutionTask = nil
                    self.setRootPath("")
                    self.setRootStatusMessage(
                        String(
                            localized: "fileExplorer.status.sshHomeFailed",
                            defaultValue: "Unable to resolve SSH home: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func cancelRemoteHomeResolution() {
        remoteHomeResolutionTask?.cancel()
        remoteHomeResolutionTask = nil
        remoteHomeResolutionKey = nil
    }

    private func setRootStatusMessage(_ message: String?) {
        guard rootStatusMessage != message else { return }
        rootStatusMessage = message
    }

    private static func path(_ candidate: String, isContainedIn root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    deinit {
        cancelRemoteHomeResolution()
    }
}

// MARK: - Directory Watcher

/// Watches a local directory for filesystem changes and calls back on the main thread.
/// Debounces events to avoid rapid-fire reloads during bulk operations (e.g., git checkout).
final class FileExplorerDirectoryWatcher {
    private var fileDescriptor: Int32 = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.cmux.fileExplorerWatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(path: String) {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        watchSource = source
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchSource?.cancel()
        watchSource = nil
        fileDescriptor = -1
    }

    private func scheduleReload() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.onChange()
            }
        }
        debounceWorkItem = work
        watchQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit {
        stop()
    }
}

// MARK: - Git Status

enum GitFileStatus {
    case modified, added, deleted, renamed, untracked
}

/// Runs `git status --porcelain` and parses results into a path-to-status map.
enum GitStatusProvider {

    static func fetchStatus(directory: String) -> [String: GitFileStatus] {
        guard let repoRoot = gitRepoRoot(for: directory) else { return [:] }
        return parseGitStatus(
            output: runGit(in: repoRoot, arguments: ["status", "--porcelain"]),
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    static func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(escapedDir)' 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && echo '---GIT_STATUS---' && git status --porcelain 2>/dev/null"
        guard let output = runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return [:] }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return [:] }
        let repoRoot = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return parseGitStatus(output: parts[1], repoRoot: repoRoot, explorerRoot: directory)
    }

    private static func parseGitStatus(
        output: String?, repoRoot: String, explorerRoot: String
    ) -> [String: GitFileStatus] {
        guard let output, !output.isEmpty else { return [:] }
        var statusMap: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")

            if path.contains(" -> ") {
                path = String(path.split(separator: " -> ").last ?? Substring(path))
            }

            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else { continue }

            let absolutePath = repoRoot.hasSuffix("/") ? repoRoot + path : repoRoot + "/" + path
            guard absolutePath.hasPrefix(explorerRoot) else { continue }

            statusMap[absolutePath] = status
            markParentDirectories(absolutePath: absolutePath, explorerRoot: explorerRoot, status: status, in: &statusMap)
        }
        return statusMap
    }

    private static func parseStatusChars(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "A" || workTree == "A" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    private static func markParentDirectories(
        absolutePath: String, explorerRoot: String,
        status: GitFileStatus, in map: inout [String: GitFileStatus]
    ) {
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while current.hasPrefix(explorerRoot) && current != explorerRoot {
            if map[current] == nil {
                map[current] = dirStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func gitRepoRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runSSH(
        command: String, destination: String,
        port: Int?, identityFile: String?, sshOptions: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = []
        if let port { args += ["-p", String(port)] }
        if let identityFile { args += ["-i", identityFile] }
        for option in sshOptions { args += ["-o", option] }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [destination, command]
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

public import Foundation

/// The production ``SSHFileExplorerTransport`` that shells out to `/usr/bin/ssh`.
///
/// Runs each operation as a child `ssh` process off Swift's cooperative executor
/// (the blocking `waitUntilExit` would otherwise stall the pool) and bridges
/// cancellation to `Process.terminate()` via a ``ProcessTerminationGate``. Home
/// resolution and listing capture stdout; download streams stdout into a local file.
public final class ProcessSSHFileExplorerTransport: SSHFileExplorerTransport, Sendable {
    /// The shared process-based transport used by SSH file-explorer providers.
    public static let shared = ProcessSSHFileExplorerTransport()

    /// Creates a process-based SSH transport.
    public init() {}

    public nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: #"printf '%s\n' "$HOME""#
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        try await Self.runSSHListCommand(path: path, connection: connection, showHidden: showHidden)
    }

    public nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        let escapedPath = Self.shellSingleQuote(path)
        let outputURL = localURL
        let commandProcess = SSHDownloadCommandProcess(
            connection: connection,
            command: "cat -- \(escapedPath)",
            outputURL: outputURL
        )
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
    }

    private struct SSHCommandResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    // Keeps the child process reachable from the cancellation handler while
    // the blocking wait runs off Swift's cooperative executor.
    private final class SSHCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private let terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            do {
                try process.run()
            } catch {
                terminationGate.markFinished()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            lock.unlock()
            if terminationGate.markLaunched() || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    terminationGate.markFinished()
                    throw CancellationError()
                }
                process.terminate()
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            terminationGate.markFinished()
            lock.lock()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: String(data: data, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            lock.unlock()

            guard terminationGate.requestTermination() else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private final class SSHDownloadCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let outputURL: URL
        private let lock = NSLock()
        private let terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String, outputURL: URL) {
            self.outputURL = outputURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }

            do {
                try process.run()
            } catch {
                terminationGate.markFinished()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            lock.unlock()
            if terminationGate.markLaunched() || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    terminationGate.markFinished()
                    throw CancellationError()
                }
                process.terminate()
            }

            try outPipe.fileHandleForReading.copyDataToEndOfFile(to: outputHandle)
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            terminationGate.markFinished()
            lock.lock()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            lock.unlock()

            guard terminationGate.requestTermination() else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private static func runSSHCommand(connection: SSHFileExplorerConnection, command: String) async throws -> String {
        let commandProcess = SSHCommandProcess(connection: connection, command: command)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }

        guard result.terminationStatus == 0 else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        return result.stdout
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
        let escapedPath = shellSingleQuote(path)
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        let output = try await runSSHCommand(
            connection: connection,
            command: "ls \(lsFlags) \(escapedPath) 2>/dev/null"
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

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

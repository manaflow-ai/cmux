import CmuxFileTree
import CmuxFoundation
import Foundation

final class ProcessSSHFileExplorerTransport: SSHFileExplorerTransport, @unchecked Sendable {
    static let shared = ProcessSSHFileExplorerTransport()

    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: #"printf '%s\n' "$HOME""#
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func listDirectories(
        paths: [String],
        connection: SSHFileExplorerConnection
    ) async throws -> [String: Result<FileTreeListing, any Error>] {
        guard !paths.isEmpty else { return [:] }
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: Self.batchListCommand(paths: paths)
        )
        return Self.parseBatchListOutput(output, paths: paths)
    }

    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        let escapedPath = Self.remoteShellPathWord(path)
        let outputURL = localURL
        let commandProcess = SSHDownloadCommandProcess(
            connection: connection,
            command: "test -f \(escapedPath) && cat -- \(escapedPath)",
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
        private var terminationGate = ProcessTerminationGate()
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
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
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
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
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
        private var terminationGate = ProcessTerminationGate()
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
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            try outPipe.fileHandleForReading.copyDataToEndOfFile(to: outputHandle)
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
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
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
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
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
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

    /// Record separators around each directory's listing. `ls` never prints
    /// these control bytes for ordinary names, and the parser also keys each
    /// section by position, not by the echoed path.
    private static let sectionStart = "\u{1e}"
    private static let sectionEnd = "\u{1f}"

    /// One remote shell command that lists every path in order, so restoring
    /// an expanded tree costs one SSH round trip over the workspace's shared
    /// ControlMaster instead of one per directory.
    static func batchListCommand(paths: [String]) -> String {
        let words = paths.map(remoteShellPathWord).joined(separator: " ")
        return "for p in \(words); do printf '\\036\\n'; ls -1paFA -- \"$p\" 2>/dev/null; " +
            "printf '\\037%s\\n' \"$?\"; done"
    }

    static func parseBatchListOutput(
        _ output: String,
        paths: [String]
    ) -> [String: Result<FileTreeListing, any Error>] {
        var results: [String: Result<FileTreeListing, any Error>] = [:]
        var sectionIndex = -1
        var lines: [Substring] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == sectionStart {
                sectionIndex += 1
                lines = []
                continue
            }
            if line.hasPrefix(sectionEnd) {
                guard sectionIndex >= 0, sectionIndex < paths.count else { continue }
                let path = paths[sectionIndex]
                let status = line.dropFirst(sectionEnd.count)
                if status == "0" {
                    results[path] = .success(FileTreeListing(entries: parseListing(lines, path: path)))
                } else {
                    results[path] = .failure(FileExplorerError.sshCommandFailed("ls exited \(status)"))
                }
                lines = []
                continue
            }
            lines.append(line)
        }
        for path in paths where results[path] == nil {
            results[path] = .failure(FileExplorerError.sshCommandFailed("missing listing"))
        }
        return results
    }

    /// Parses `ls -1paFA` output. `-F` marks directories with `/` and
    /// symlinks, executables, sockets and FIFOs with `@`, `*`, `=` and `|`.
    static func parseListing(_ lines: [Substring], path: String) -> [FileTreeEntry] {
        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return lines.compactMap { line in
            guard !line.isEmpty, line != "./", line != "../" else { return nil }
            if line.hasSuffix("/") {
                let name = String(line.dropLast())
                return FileTreeEntry(name: name, path: normalizedPath + name, kind: .directory)
            }
            var name = String(line)
            var kind = FileTreeEntryKind.file
            if let last = name.last, "*@=|".contains(last) {
                name.removeLast()
                switch last {
                case "@": kind = .symbolicLink
                case "=", "|": kind = .other
                default: kind = .file
                }
            }
            return FileTreeEntry(name: name, path: normalizedPath + name, kind: kind)
        }
    }

    /// Shell word that expands to `path` on the remote host, byte for byte.
    ///
    /// `Process` passes arguments through `fileSystemRepresentation`, which
    /// decomposes them to NFD. Remote Linux filesystems usually store names in
    /// NFC and treat the two forms as different files, so a non-ASCII path must
    /// not appear literally in the ssh command. Such paths travel base64-encoded
    /// and are decoded by the remote shell.
    static func remoteShellPathWord(_ path: String) -> String {
        guard !path.unicodeScalars.allSatisfy(\.isASCII) else {
            return shellSingleQuote(path)
        }
        let encoded = shellSingleQuote(Data(path.utf8).base64EncodedString())
        // GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
        // -D is the older macOS short flag.
        let decode = ["--decode", "-d", "-D"]
            .map { "printf '%s' \(encoded) | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        return "\"$(\(decode))\""
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

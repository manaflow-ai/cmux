import Darwin
import Foundation

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

    // Shared with termination/readability callbacks; mutable process state is
    // guarded by lock and output/waiter helpers have their own locks.
    private final class CommandProcess: @unchecked Sendable {
        // FileHandle readability callbacks can run off the creating task; all
        // mutable output buffers are protected by lock.
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

        // Process.terminationHandler resumes continuations from a callback
        // thread; status and continuation storage are protected by lock.
        private final class TerminationWaiter: @unchecked Sendable {
            private let lock = NSLock()
            private var status: Int32?
            private var continuations: [CheckedContinuation<Int32, Never>] = []

            func wait() async -> Int32 {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if let status {
                        lock.unlock()
                        continuation.resume(returning: status)
                        return
                    }
                    continuations.append(continuation)
                    lock.unlock()
                }
            }

            func finish(status: Int32) {
                lock.lock()
                if self.status != nil {
                    lock.unlock()
                    return
                }
                self.status = status
                let continuations = self.continuations
                self.continuations.removeAll()
                lock.unlock()

                for continuation in continuations {
                    continuation.resume(returning: status)
                }
            }
        }

        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private var cancelled = false
        private var started = false

        init(executable: String, arguments: [String]) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run(timeout: TimeInterval? = nil) async throws -> SSHCommandResult {
            if isCancelled {
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

            if markStartedAndShouldTerminate {
                process.terminate()
                scheduleForceKillAfterGraceUnlessTerminated(waiter: terminationWaiter)
            }

            let terminationStatus: Int32
            do {
                terminationStatus = try await withTaskCancellationHandler {
                    try await waitForTermination(timeout: timeout, waiter: terminationWaiter)
                } onCancel: {
                    self.terminate()
                    self.scheduleForceKillAfterGraceUnlessTerminated(waiter: terminationWaiter)
                }
            } catch {
                if case FileExplorerError.downloadTimedOut = error {
                    _ = await terminationWaiter.wait()
                } else {
                    terminate()
                    await forceKillAfterGraceUnlessTerminated(waiter: terminationWaiter)
                    _ = await terminationWaiter.wait()
                }
                _ = outputCollector.finish()
                process.terminationHandler = nil
                throw error
            }
            let output = outputCollector.finish()
            process.terminationHandler = nil
            try Task.checkCancellation()

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

        private var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        private var markStartedAndShouldTerminate: Bool {
            lock.lock()
            started = true
            let shouldTerminate = cancelled && process.isRunning
            lock.unlock()
            return shouldTerminate
        }

        private func terminateForTimeout() {
            lock.lock()
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

        private enum TerminationRaceResult: Sendable {
            case terminated(Int32)
            case timedOut
        }

        private func scheduleForceKillAfterGraceUnlessTerminated(waiter: TerminationWaiter) {
            _ = Task.detached(priority: .utility) { [self, waiter] in
                await forceKillAfterGraceUnlessTerminated(waiter: waiter)
            }
        }

        private func waitForTermination(timeout: TimeInterval?, waiter: TerminationWaiter) async throws -> Int32 {
            guard let timeout else {
                return await waiter.wait()
            }

            let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            return try await withThrowingTaskGroup(of: TerminationRaceResult.self) { group in
                group.addTask { [waiter] in
                    .terminated(await waiter.wait())
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return .timedOut
                }

                do {
                    guard let result = try await group.next() else {
                        throw FileExplorerError.downloadTimedOut
                    }
                    group.cancelAll()
                    switch result {
                    case .terminated(let status):
                        return status
                    case .timedOut:
                        terminateForTimeout()
                        await forceKillAfterGraceUnlessTerminated(waiter: waiter)
                        throw FileExplorerError.downloadTimedOut
                    }
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        private func forceKillAfterGraceUnlessTerminated(waiter: TerminationWaiter) async {
            // This deadline must survive parent task cancellation; otherwise a
            // cancelled SCP task can SIGTERM and then wait forever if scp ignores it.
            let deadlineTask = Task.detached(priority: .utility) { [self] in
                do {
                    try await ContinuousClock().sleep(for: .seconds(1))
                } catch {
                    return
                }
                forceKillIfRunning()
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [waiter] in
                    _ = await waiter.wait()
                }
                group.addTask {
                    await deadlineTask.value
                }

                _ = await group.next()
                deadlineTask.cancel()
                group.cancelAll()
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
            throw FileExplorerError.sshCommandFailed(
                remoteCommandFailureDetail(status: result.terminationStatus)
            )
        }
        return result.stdout
    }

    private static func runSCPCommand(arguments: [String], timeout: TimeInterval) async throws -> SSHCommandResult {
        let commandProcess = CommandProcess(executable: scpExecutablePath, arguments: arguments)
        do {
            return try await withTaskCancellationHandler {
                try await commandProcess.run(timeout: timeout)
            } onCancel: {
                commandProcess.terminate()
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as FileExplorerError {
            throw error
        } catch {
            throw FileExplorerError.downloadFailed(downloadHelperLaunchFailureDetail())
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
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        let output = try await runSSHCommand(
            connection: connection,
            command: "ls \(lsFlags) \(ShellArgumentQuoting.singleQuoted(path)) 2>/dev/null"
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
        let target = try downloadTarget(remotePath: remotePath, localDirectory: localDirectory)
        let args = scpDownloadArguments(
            remotePath: remotePath,
            isDirectory: isDirectory,
            connection: connection,
            localDestinationPath: target.path
        )
        let result = try await runSCPCommand(arguments: args, timeout: 30 * 60)
        guard result.terminationStatus == 0 else {
            throw FileExplorerError.downloadFailed(
                remoteCommandFailureDetail(status: result.terminationStatus)
            )
        }
        return target.path
    }

    private struct DownloadTarget {
        let path: String
    }

    private static func downloadTarget(remotePath: String, localDirectory: String) throws -> DownloadTarget {
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
        if FileManager.default.fileExists(atPath: targetPath) {
            let detail = String.localizedStringWithFormat(
                String(
                    localized: "fileExplorer.error.downloadTargetExists",
                    defaultValue: "A local item already exists at %@"
                ),
                targetPath
            )
            throw FileExplorerError.downloadFailed(detail)
        }

        return DownloadTarget(path: targetPath)
    }

    private static func scpDownloadArguments(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        localDestinationPath: String
    ) -> [String] {
        var args: [String] = [
            "-q",
            "-O",
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
        let effectiveSSHOptions = SSHCommandArgumentSupport.backgroundOptions(connection.sshOptions)
        if !SSHCommandArgumentSupport.hasOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }

        args += [
            "\(SSHCommandArgumentSupport.scpRemoteDestination(connection.destination)):\(ShellArgumentQuoting.singleQuoted(remotePath))",
            localDestinationPath,
        ]
        return args
    }

    private static var scpExecutablePath: String {
#if DEBUG
        if let scpExecutablePathOverrideForTesting {
            return scpExecutablePathOverrideForTesting
        }
#endif
        return "/usr/bin/scp"
    }

    private static func remoteCommandFailureDetail(status: Int32) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "fileExplorer.error.remoteCommandExited",
                defaultValue: "Remote command exited with status %d."
            ),
            Int(status)
        )
    }

    private static func downloadHelperLaunchFailureDetail() -> String {
        String(
            localized: "fileExplorer.error.downloadHelperUnavailable",
            defaultValue: "Unable to start the download helper."
        )
    }

#if DEBUG
    nonisolated(unsafe) static var scpExecutablePathOverrideForTesting: String?

    static func downloadTargetPathForTesting(remotePath: String, localDirectory: String) throws -> String {
        try downloadTarget(remotePath: remotePath, localDirectory: localDirectory).path
    }

    static func scpDownloadArgumentsForTesting(
        remotePath: String,
        isDirectory: Bool,
        connection: SSHFileExplorerConnection,
        localDestinationPath: String
    ) -> [String] {
        scpDownloadArguments(
            remotePath: remotePath,
            isDirectory: isDirectory,
            connection: connection,
            localDestinationPath: localDestinationPath
        )
    }
#endif
}

import Darwin
public import Foundation
import os

/// Production hook-process runner backed by `Process`.
public struct HookProcessRunner: HookProcessRunning {
    private static let stderrLimitBytes = 64 * 1024
    private static let sigkillGraceSeconds: Double = 0.2
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxHooks.timer")

    private let environment: [String: String]
    private let fallbackSearchDirectories: [String]

    /// Creates a process runner.
    /// - Parameters:
    ///   - environment: Environment used for PATH lookup.
    ///   - fallbackSearchDirectories: Directories searched after PATH for bare commands.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackSearchDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    ) {
        self.environment = environment
        self.fallbackSearchDirectories = fallbackSearchDirectories
    }

    /// Executes a hook process.
    /// - Parameters:
    ///   - command: Absolute path or command name to execute.
    ///   - arguments: Arguments passed to the command.
    ///   - stdin: Bytes written to the hook's stdin.
    ///   - timeout: Deadline for the hook process.
    /// - Returns: Captured process output and terminal status.
    public func run(command: String, arguments: [String], stdin: Data, timeout: Duration) async -> HookProcessResult {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if let resolved = resolvedCommandPath(executable: command) {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        let inFD = Darwin.dup(stdinPipe.fileHandleForWriting.fileDescriptor)
        guard inFD >= 0 else {
            return HookProcessResult(
                exitStatus: nil,
                stdout: Data(),
                stderr: Data(),
                timedOut: false,
                launchFailure: "failed to duplicate hook stdin pipe: \(String(cString: strerror(errno)))"
            )
        }
        _ = Darwin.fcntl(inFD, F_SETNOSIGPIPE, 1)

        return await withCheckedContinuation { continuation in
            // A one-shot continuation can be completed by process termination, timeout,
            // launch failure, or pipe EOF callbacks; a tiny lock keeps those synchronous
            // callbacks from racing multiple resumes without adding actor hops.
            let state = OSAllocatedUnfairLock(initialState: HookRunState())

            @Sendable func recordAndCompleteIfReady(_ mutate: @Sendable (inout HookRunState) -> Void) {
                let (completed, timerToCancel): (HookProcessResult?, (any DispatchSourceTimer)?) =
                    state.withLock { s in
                        mutate(&s)
                        guard !s.resumed, let stdout = s.stdout, let stderr = s.stderr, s.didTerminate else {
                            return (nil, nil)
                        }
                        s.resumed = true
                        let timer = s.deadlineTimer
                        s.deadlineTimer = nil
                        return (
                            HookProcessResult(
                                exitStatus: s.exitStatus,
                                stdout: stdout,
                                stderr: Self.capped(stderr, limit: Self.stderrLimitBytes),
                                timedOut: false,
                                launchFailure: nil
                            ),
                            timer
                        )
                    }
                timerToCancel?.cancel()
                if let completed { continuation.resume(returning: completed) }
            }

            @Sendable func claimImmediate(_ result: HookProcessResult) -> Bool {
                let (won, timerToCancel): (Bool, (any DispatchSourceTimer)?) =
                    state.withLock { s in
                        if s.resumed { return (false, nil) }
                        s.resumed = true
                        let timer = s.deadlineTimer
                        s.deadlineTimer = nil
                        return (true, timer)
                    }
                timerToCancel?.cancel()
                if won { continuation.resume(returning: result) }
                return won
            }

            Task.detached {
                let data = Self.readToEnd(fileDescriptor: outFD)
                recordAndCompleteIfReady { $0.stdout = data }
            }
            Task.detached {
                let data = Self.readToEnd(fileDescriptor: errFD)
                recordAndCompleteIfReady { $0.stderr = data }
            }

            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                recordAndCompleteIfReady {
                    $0.didTerminate = true
                    $0.exitStatus = status
                }
            }

            do {
                try process.run()
            } catch {
                try? stdinPipe.fileHandleForWriting.close()
                Darwin.close(inFD)
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = claimImmediate(HookProcessResult(
                    exitStatus: nil,
                    stdout: Data(),
                    stderr: Data(),
                    timedOut: false,
                    launchFailure: String(describing: error)
                ))
                return
            }

            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForWriting.close()

            let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
            timer.schedule(deadline: .now() + timeout.timeInterval)
            timer.setEventHandler {
                if claimImmediate(HookProcessResult(
                    exitStatus: nil,
                    stdout: Data(),
                    stderr: Data(),
                    timedOut: true,
                    launchFailure: nil
                )), process.isRunning {
                    process.terminate()
                    Self.scheduleSigkill(process)
                }
                timer.cancel()
            }
            let alreadyResumed = state.withLock { s -> Bool in
                if s.resumed { return true }
                s.deadlineTimer = timer
                return false
            }
            if alreadyResumed {
                timer.cancel()
            } else {
                timer.resume()
            }
            Task.detached {
                Self.writeAll(stdin, to: inFD)
                Darwin.close(inFD)
            }
        }
    }

    private func resolvedCommandPath(executable: String) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []
        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty, seenDirectories.insert(component).inserted else { continue }
                searchDirectories.append(component)
            }
        }
        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        fallbackSearchDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func scheduleSigkill(_ process: Process) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            timer.cancel()
        }
        timer.resume()
    }

    private static func readToEnd(fileDescriptor: Int32) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private static func capped(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        return data.prefix(limit)
    }
}

private struct HookRunState {
    var stdout: Data?
    var stderr: Data?
    var didTerminate = false
    var exitStatus: Int32?
    var resumed = false
    var deadlineTimer: (any DispatchSourceTimer)?
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

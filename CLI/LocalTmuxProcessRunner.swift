import Darwin
import Foundation

struct LocalTmuxProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

/// Runs short-lived tmux control commands without inheriting cmux socket secrets.
struct LocalTmuxProcessRunner {
    let executablePath: String
    let environment: [String: String]

    private let maxCapturedOutputBytes = 8 * 1024 * 1024
    private let commandTimeout: TimeInterval = 30

    init(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executablePath = executablePath
        var sanitized = environment
        sanitized.removeValue(forKey: "TMUX")
        sanitized.removeValue(forKey: "CMUX_SOCKET_PASSWORD")
        sanitized.removeValue(forKey: "CMUX_SOCKET")
        sanitized.removeValue(forKey: "CMUX_SOCKET_PATH")
        sanitized.removeValue(forKey: "CMUX_SOCKET_PASSWORD_FILE")
        // A detached owner must not retain a stale workspace/surface identity
        // or a socket credential from the GUI that launched it.
        sanitized = sanitized.filter { !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("CMUXD_") }
        self.environment = sanitized
    }

    func run(arguments: [String]) throws -> LocalTmuxProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            let message = String(localized: "cli.localTmux.error.runFailed", defaultValue: "local-tmux could not run tmux")
            throw CLIError(message: "\(message): \(error)", exitCode: 127)
        }

        let stdoutFileHandle = stdoutPipe.fileHandleForReading
        let stderrFileHandle = stderrPipe.fileHandleForReading
        let stdoutFD = stdoutFileHandle.fileDescriptor
        let stderrFD = stderrFileHandle.fileDescriptor
        setNonBlocking(stdoutFD)
        setNonBlocking(stderrFD)

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutOpen = true
        var stderrOpen = true
        var didTimeout = false
        let deadline = ProcessInfo.processInfo.systemUptime + commandTimeout

        // Drain both descriptors while tmux is running. Waiting for the child
        // before reading can deadlock once either pipe's kernel buffer fills.
        while stdoutOpen || stderrOpen || process.isRunning {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                didTimeout = true
                if process.isRunning { process.terminate() }
                break
            }

            if !stdoutOpen, !stderrOpen {
                let waitMilliseconds = Int32(max(1, min(250, remaining * 1_000)))
                _ = Darwin.poll(nil, 0, waitMilliseconds)
                continue
            }

            var descriptors: [pollfd] = []
            if stdoutOpen {
                descriptors.append(pollfd(
                    fd: stdoutFD,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                ))
            }
            if stderrOpen {
                descriptors.append(pollfd(
                    fd: stderrFD,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                ))
            }
            let waitMilliseconds = Int32(max(1, min(250, remaining * 1_000)))
            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), waitMilliseconds)
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                didTimeout = true
                if process.isRunning { process.terminate() }
                break
            }
            guard pollResult > 0 else { continue }

            var descriptorIndex = 0
            if stdoutOpen {
                let events = descriptors[descriptorIndex].revents
                if events & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                    stdoutOpen = !drainAvailable(from: stdoutFD, into: &stdoutData)
                }
                descriptorIndex += 1
            }
            if stderrOpen {
                let events = descriptors[descriptorIndex].revents
                if events & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                    stderrOpen = !drainAvailable(from: stderrFD, into: &stderrData)
                }
            }
        }

        if didTimeout, process.isRunning {
            process.terminate()
            // A control command that ignores SIGTERM must not hold the CLI
            // forever after the bounded deadline.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        if stdoutOpen { _ = drainAvailable(from: stdoutFD, into: &stdoutData) }
        if stderrOpen { _ = drainAvailable(from: stderrFD, into: &stderrData) }
        if didTimeout {
            let timeoutMessage = String(localized: "cli.localTmux.error.timedOut", defaultValue: "local-tmux command timed out")
            stderrData.append(contentsOf: Data("\n\(timeoutMessage)\n".utf8))
        }

        return LocalTmuxProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    func requireSuccess(_ arguments: [String], context: String) throws -> LocalTmuxProcessResult {
        let result = try run(arguments: arguments)
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.operationFailed", defaultValue: "local-tmux %@ failed (exit %d)"),
                context,
                result.status
            )
            throw CLIError(message: detail.isEmpty ? message : "\(message): \(detail)")
        }
        return result
    }

    private func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Drains all currently available bytes and reports whether EOF was seen.
    private func drainAvailable(from descriptor: Int32, into data: inout Data) -> Bool {
        while true {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                let remainingCapacity = max(0, maxCapturedOutputBytes - data.count)
                if remainingCapacity > 0 {
                    data.append(contentsOf: buffer.prefix(min(count, remainingCapacity)))
                }
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            return true
        }
    }
}

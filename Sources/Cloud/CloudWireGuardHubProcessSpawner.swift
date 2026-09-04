import Foundation

/// Spawns `cmux-tui wg hub` as a Foundation `Process` with stdio detached from any tty;
/// stdout and stderr drain on GCD (``CloudLinkPipe``) into a short tail for diagnostics.
struct CloudWireGuardHubProcessSpawner: CloudWireGuardHubSpawning {
    func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let wrapper = CloudWireGuardHubFoundationProcess(process: process)
        process.terminationHandler = { terminated in
            wrapper.didExit(status: terminated.terminationStatus)
        }
        try process.run()
        // Read the pipes only after run(), the same order CloudMachineLink uses for the
        // sidecar's connection-snapshot line: the readabilityHandler is armed once the
        // child owns the write end.
        wrapper.beginReading(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        return wrapper
    }
}

/// ``CloudWireGuardHubProcess`` over a running Foundation `Process`. stdout is
/// handed to the hub as lines (its `hub-ready` announcement lives there); stderr is
/// kept as a short tail for error messages.
final class CloudWireGuardHubFoundationProcess: CloudWireGuardHubProcess, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var tail: [String] = []
    private var status: Int32?
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private let stdoutStream: AsyncStream<String>
    private let stdoutContinuation: AsyncStream<String>.Continuation

    init(process: Process) {
        self.process = process
        (stdoutStream, stdoutContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
    }

    var stdoutLines: AsyncStream<String> { stdoutStream }

    var isRunning: Bool { process.isRunning }

    /// Arm the pipe readers after `process.run()`, so the child owns the write ends.
    func beginReading(stdout: FileHandle, stderr: FileHandle) {
        let continuation = stdoutContinuation
        let stdoutLines = CloudLinkPipe.lines(from: stdout)
        Task.detached {
            for await line in stdoutLines { continuation.yield(line) }
            continuation.finish()
        }
        drain(stderr)
    }

    var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    var outputTail: String {
        lock.lock()
        defer { lock.unlock() }
        return tail.joined(separator: "\n")
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if let status {
            lock.unlock()
            handler(status)
            return
        }
        exitHandler = handler
        lock.unlock()
    }

    fileprivate func didExit(status: Int32) {
        lock.lock()
        self.status = status
        let handler = exitHandler
        exitHandler = nil
        lock.unlock()
        handler?(status)
    }

    fileprivate func drain(_ handle: FileHandle) {
        let lines = CloudLinkPipe.lines(from: handle)
        Task.detached { [weak self] in
            for await line in lines {
                self?.record(line)
            }
        }
    }

    private func record(_ line: String) {
        lock.lock()
        tail.append(line)
        if tail.count > 20 { tail.removeFirst(tail.count - 20) }
        lock.unlock()
    }
}

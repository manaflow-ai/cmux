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
        wrapper.drain(stdout.fileHandleForReading)
        wrapper.drain(stderr.fileHandleForReading)
        return wrapper
    }
}

/// ``CloudWireGuardHubProcess`` over a running Foundation `Process`.
///
/// `Process` callbacks are synchronous and can race exit registration and pipe
/// delivery. The short lock protects only this callback seam; callers see the
/// actor-owned ``CloudWireGuardHub`` lifecycle.
final class CloudWireGuardHubFoundationProcess: CloudWireGuardHubProcess, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var tail: [String] = []
    private var status: Int32?
    private var exitHandler: (@Sendable (Int32) -> Void)?

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

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

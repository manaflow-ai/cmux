public import Foundation
import CmuxNextCompat

/// One running `cmux-mobile-host` child: its stdout as event lines, its stdin for
/// control lines, its stderr appended to a log file. Reading happens on
/// Foundation's pipe queue, never the caller's actor. The child exits by
/// itself when stdin closes, so a crash of the app ends it too.
public final class MobileHostProcess: Sendable {
    private struct State {
        var process: Process?
        var input: FileHandle?
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    }

    /// Every stdout line, bounded by backpressure on the pipe reader.
    public let lines: AsyncStream<String>
    private let queue = MobileHostQueue<String>(capacity: 256)
    private let state = Mutex(State())

    public init() {
        lines = queue.stream
    }

    /// Starts `launch.executable` with `environment`; stderr goes to `log` (created 0600) or nowhere.
    public func start(_ launch: MobileHostLaunch, environment: [String: String], log: URL?) throws {
        let process = Process()
        process.executableURL = launch.executable
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Self.logHandle(log) ?? FileHandle.nullDevice
        // A write after hostd exited must fail with EPIPE, not raise SIGPIPE in the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let buffer = LineBuffer()
        let queue = queue
        output.fileHandleForReading.readabilityHandler = { handle in
            switch handle.readReady() {
            case .bytes(let data): for line in buffer.append(data) { queue.push(line) }
            case .retry: return
            case .end:
                handle.readabilityHandler = nil
                queue.finish()
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let waiters = self?.state.withLock { state -> [CheckedContinuation<Int32, Never>] in
                state.exitStatus = status
                try? state.input?.close()
                state.input = nil
                defer { state.exitWaiters.removeAll() }
                return state.exitWaiters
            } ?? []
            for waiter in waiters { waiter.resume(returning: status) }
        }
        state.withLock {
            $0.process = process
            $0.input = input.fileHandleForWriting
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            queue.cancel()
            state.withLock {
                try? $0.input?.close()
                $0.input = nil
                $0.process = nil
            }
            throw error
        }
    }

    /// Writes one control line; false when hostd is gone.
    @discardableResult
    public func send(_ line: Data) -> Bool {
        state.withLock { state in
            guard state.exitStatus == nil, let input = state.input else { return false }
            do {
                try input.write(contentsOf: line)
                return true
            } catch {
                return false
            }
        }
    }

    public var pid: Int32? { state.withLock { $0.process?.processIdentifier } }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { waiter in
            let done = state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.exitWaiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }
    }

    /// Closes stdin (hostd exits on its own) and sends SIGTERM.
    public func stop() {
        queue.cancel()
        let process = state.withLock { state -> Process? in
            try? state.input?.close()
            state.input = nil
            return state.exitStatus == nil ? state.process : nil
        }
        process?.terminate()
    }

    /// The log file opened for appending, created with mode 0600 and
    /// started over once it passes 1 MB.
    static func logHandle(_ url: URL?) -> FileHandle? {
        guard let url else { return nil }
        let path = url.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 1 << 20 { try? FileManager.default.removeItem(atPath: path) }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// hostd's stdout split into lines; a line over 1 MB drops the buffer (hostd never writes one).
private final class LineBuffer: Sendable {
    private let splitter = Mutex(LineSplitter(maximumLineBytes: 1 << 20))

    func append(_ data: Data) -> [String] {
        splitter.withLock { splitter in
            do {
                return try splitter.append(data).map { String(decoding: $0, as: UTF8.self) }
            } catch {
                splitter = LineSplitter(maximumLineBytes: 1 << 20)
                return []
            }
        }
    }
}

package import Foundation
import Synchronization

/// A cmux-tui helper process (`wg hub`, `remote connect`) whose stdout is a
/// stream of JSON lines. Reading happens on Foundation's pipe threads, never
/// the main actor. Stdout lines are bounded (drop-oldest past 256 pending);
/// stderr keeps a 4 KB tail for error messages. The child runs with
/// `--exit-with-parent`, so a crash of this app ends it too.
package final class ChildProcess: Sendable {
    private struct State {
        var process: Process?
        var stderrTail = Data()
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    }

    package let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let state = Mutex(State())
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]

    package init(executable: URL, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        (lines, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
    }

    package func start() throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let splitter = LineSplitter()
        let continuation = continuation
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in splitter.append(data) { continuation.yield(line) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.state.withLock { state in
                state.stderrTail.append(data)
                if state.stderrTail.count > 4096 { state.stderrTail.removeFirst(state.stderrTail.count - 4096) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let waiters = self?.state.withLock { state -> [CheckedContinuation<Int32, Never>] in
                state.exitStatus = status
                defer { state.exitWaiters.removeAll() }
                return state.exitWaiters
            } ?? []
            for waiter in waiters { waiter.resume(returning: status) }
        }
        state.withLock { $0.process = process }
        try process.run()
    }

    package var pid: Int32? { state.withLock { $0.process?.processIdentifier } }
    package var isRunning: Bool { state.withLock { $0.process != nil && $0.exitStatus == nil } }

    package var stderrText: String {
        let data = state.withLock { $0.stderrTail }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func waitForExit() async -> Int32 {
        await withCheckedContinuation { waiter in
            let done = state.withLock { state -> Int32? in
                if let status = state.exitStatus { return status }
                state.exitWaiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }
    }

    /// SIGTERM; the helpers exit and remove their sockets.
    package func terminate() {
        let process = state.withLock { $0.exitStatus == nil ? $0.process : nil }
        process?.terminate()
    }

    /// The first stdout line `match` accepts, within `deadline`. Throws when
    /// the process exits first (with its stderr) or the deadline passes.
    package func firstLine<T: Sendable>(within deadline: Duration, label: String,
                                _ match: @escaping @Sendable (String) -> T?) async throws -> T {
        let lines = lines
        return try await withDeadline(deadline, label: label) { [weak self] in
            for await line in lines {
                if let value = match(line) { return value }
            }
            throw ChildProcessError.exited(label: label, stderr: self?.stderrText ?? "")
        }
    }
}

package enum ChildProcessError: Error, Sendable, CustomStringConvertible {
    case exited(label: String, stderr: String)
    case missingBinary(String)

    package var description: String {
        switch self {
        case .exited(let label, let stderr): stderr.isEmpty ? "\(label) exited" : "\(label) exited: \(stderr)"
        case .missingBinary(let path): "cmux-tui not found at \(path)"
        }
    }
}

/// Splits a byte stream into newline-terminated UTF-8 lines.
final class LineSplitter: Sendable {
    private let buffer = Mutex(Data())

    func append(_ data: Data) -> [String] {
        buffer.withLock { buffer in
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > 1 << 20 { buffer.removeAll() }
            return lines
        }
    }
}

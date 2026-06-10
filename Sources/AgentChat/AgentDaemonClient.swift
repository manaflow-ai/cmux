import Foundation

/// A newline-delimited-JSON RPC client over a spawned `cmuxd-remote serve
/// --stdio` child process.
///
/// Requests are `{id, method, params}` answered by `{id, ok, result|error}`;
/// unsolicited frames carry an `event` key and are forwarded to `onEvent`.
/// The child's lifetime is bound to this client: `terminate()` (or deinit)
/// kills it. Reading is callback-driven off the pipe (no polling threads).
final class AgentDaemonClient: @unchecked Sendable {
    struct DaemonError: Error, LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    /// Unsolicited daemon frames (objects containing an `event` key).
    var onEvent: (@Sendable ([String: Any]) -> Void)?
    /// Called once when the child exits, with its termination status.
    var onTermination: (@Sendable (Int32) -> Void)?

    private let binaryURL: URL
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    private let lock = NSLock()
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readBuffer = Data()
    private var started = false
    private var terminated = false

    init(binaryURL: URL) {
        self.binaryURL = binaryURL
    }

    deinit {
        terminate()
    }

    /// Spawns the child and starts the read loop. Throws when the binary
    /// cannot be launched.
    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        process.executableURL = binaryURL
        process.arguments = ["serve", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(status: finished.terminationStatus)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        try process.run()
    }

    /// Allocates the next request id, failing once the client is terminated.
    /// Synchronous so the NSLock never spans a suspension point.
    private func allocateRequestId() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if terminated {
            throw DaemonError(code: "terminated", message: "agent daemon is not running")
        }
        let requestId = nextRequestId
        nextRequestId += 1
        return requestId
    }

    /// Sends one request and awaits its response's `result` object.
    func request(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let requestId = try allocateRequestId()
        let frame: [String: Any] = ["id": requestId, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: frame)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.resume(throwing: DaemonError(code: "terminated", message: "agent daemon exited"))
                return
            }
            pending[requestId] = continuation
            lock.unlock()
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            } catch {
                lock.lock()
                let pendingContinuation = pending.removeValue(forKey: requestId)
                lock.unlock()
                pendingContinuation?.resume(throwing: error)
            }
        }
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = started && !terminated
        terminated = true
        lock.unlock()
        guard shouldTerminate else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        failAllPending(DaemonError(code: "terminated", message: "agent daemon terminated"))
    }

    private func consume(_ data: Data) {
        lock.lock()
        readBuffer.append(data)
        var frames: [[String: Any]] = []
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let frame = object as? [String: Any] else {
                continue
            }
            frames.append(frame)
        }
        lock.unlock()
        for frame in frames {
            dispatch(frame)
        }
    }

    private func dispatch(_ frame: [String: Any]) {
        if frame["event"] is String {
            onEvent?(frame)
            return
        }
        guard let id = requestIdValue(frame["id"]) else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if (frame["ok"] as? Bool) == true {
            continuation.resume(returning: (frame["result"] as? [String: Any]) ?? [:])
        } else {
            let errorObject = frame["error"] as? [String: Any]
            continuation.resume(throwing: DaemonError(
                code: (errorObject?["code"] as? String) ?? "error",
                message: (errorObject?["message"] as? String) ?? "agent daemon request failed"
            ))
        }
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        let alreadyTerminated = terminated
        terminated = true
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        failAllPending(DaemonError(code: "exited", message: "agent daemon exited (status \(status))"))
        if !alreadyTerminated {
            onTermination?(status)
        }
    }

    private func failAllPending(_ error: DaemonError) {
        lock.lock()
        let continuations = pending
        pending = [:]
        lock.unlock()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func requestIdValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return nil
    }
}

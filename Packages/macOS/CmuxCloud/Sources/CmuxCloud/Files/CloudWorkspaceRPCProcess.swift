import Darwin
import Foundation
import os

nonisolated private let workspaceRPCLog = Logger(subsystem: "com.cmuxterm.app", category: "CloudWorkspaceRPC")

/// Owns one VM's `cmux-tui remote rpc --stream` carrier: a persistent, authenticated
/// channel to the guest daemon's workspace file service.
///
/// Each request is one JSON line tagged with an id; the child answers each id once and
/// keeps the channel open across RPC errors, so a missing file does not cost a reconnect.
/// Canceling a caller's task sends `cancel` for its id, which cancels it on the daemon.
public actor CloudWorkspaceRPCProcess {
    /// A daemon-side `RpcError` for one request. The channel stays usable.
    public struct RemoteError: Error, Sendable, Equatable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var exit: CloudLinkFirstValue<Int32>?
    private var releaseHub: (@Sendable () async -> Void)?
    private var ready = false
    private var stopped = false
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    public init() {}

    /// Whether the child is running and has reported ready.
    public var isReady: Bool { ready && !stopped && process?.isRunning == true }

    /// Starts the child and waits for its `{"ready":true}` line.
    public func start(client: URL, arguments: [String], environment: [String: String]? = nil, releaseHub: @escaping @Sendable () async -> Void) async throws {
        guard !stopped else {
            await releaseHub()
            throw CancellationError()
        }
        self.releaseHub = releaseHub
        let child = Process()
        let stdin = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let ended = CloudLinkFirstValue<Int32>()
        let readyLine = CloudLinkFirstValue<Bool>()
        child.executableURL = client
        child.arguments = arguments
        child.environment = CloudBrowserProxyProcess.sanitizedEnvironment(environment ?? ProcessInfo.processInfo.environment)
        child.standardInput = stdin
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { terminated in
            ended.resolve(terminated.terminationStatus)
            readyLine.resolve(nil)
        }
        do { try child.run() } catch {
            await releaseClaim()
            throw error
        }
        process = child
        // A write after the child exits must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = stdin.fileHandleForWriting
        exit = ended
        let lines = CloudLinkPipe.lines(from: output.fileHandleForReading)
        Task { [weak self] in
            var ready = false
            for await line in lines {
                // File contents flow through stdout. Never log it.
                guard let data = line.data(using: .utf8) else { continue }
                if !ready, Self.isReadyLine(data) {
                    ready = true
                    readyLine.resolve(true)
                    continue
                }
                await self?.deliver(data)
            }
            readyLine.resolve(nil)
        }
        let errorLines = CloudLinkPipe.lines(from: errors.fileHandleForReading)
        Task {
            for await line in errorLines {
                workspaceRPCLog.debug("workspace rpc carrier: \(line, privacy: .private)")
            }
        }
        Task { [weak self] in
            let status = await ended.result
            await self?.didExit(status: status ?? -1)
        }
        do {
            let value = try await withThrowingTaskGroup(of: Bool?.self) { group in
                group.addTask { await readyLine.result }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw CloudMachineLink.LinkError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            try Task.checkCancellation()
            guard !stopped, child.isRunning, value == true else {
                throw CloudMachineLink.LinkError.exited(status: child.isRunning ? Int32(-1) : child.terminationStatus, output: "")
            }
            ready = true
        } catch {
            await stop()
            throw error
        }
    }

    /// Sends one `WorkspaceRequest` (a JSON object) and returns its `WorkspaceResponse`
    /// JSON. Throws ``RemoteError`` for a daemon error and ``CloudMachineLink/LinkError``
    /// when the channel is gone.
    public func request(_ requestJSON: Data) async throws -> Data {
        guard isReady, let input else {
            throw CloudMachineLink.LinkError.exited(status: -1, output: "transport closed")
        }
        guard let request = try? JSONSerialization.jsonObject(with: requestJSON) else {
            throw RemoteError(code: "invalid-request", message: "request is not JSON")
        }
        nextID += 1
        let id = nextID
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "request": request])
        line.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                do {
                    try input.write(contentsOf: line)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: CloudMachineLink.LinkError.exited(status: -1, output: "transport closed"))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        guard var line = try? JSONSerialization.data(withJSONObject: ["id": id, "cancel": true]) else { return }
        line.append(0x0A)
        try? input?.write(contentsOf: line)
    }

    private nonisolated static func isReadyLine(_ line: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        return object?["ready"] as? Bool == true
    }

    private func deliver(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: RemoteError(
                code: error["code"] as? String ?? "internal",
                message: error["message"] as? String ?? ""
            ))
        } else if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: RemoteError(code: "internal", message: "malformed stream response"))
        }
    }

    public func stop() async {
        stopped = true
        ready = false
        failPending(status: -1)
        try? input?.close()
        input = nil
        if let process, let exit {
            // Retain Process until the termination callback has fired, even when our caller cancels.
            let finished = Task.detached { await exit.result }
            if process.isRunning { process.terminate() }
            let forceStop = Task.detached {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                // Process remains retained until its real exit, so this PID cannot be reused here.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            _ = await finished.value
            forceStop.cancel()
        }
        process = nil
        exit = nil
        await releaseClaim()
    }

    private func didExit(status: Int32) async {
        ready = false
        failPending(status: status)
        await releaseClaim()
    }

    private func failPending(status: Int32) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: CloudMachineLink.LinkError.exited(status: status, output: "transport closed"))
        }
    }

    private func releaseClaim() async {
        let release = releaseHub
        releaseHub = nil
        await release?()
    }
}

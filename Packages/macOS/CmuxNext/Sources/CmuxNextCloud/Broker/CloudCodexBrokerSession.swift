import CmuxNextCompat
import Darwin
public import Foundation

nonisolated struct BrokerRequest: Encodable, Sendable {
    let id: Int
    let method: String
    let force: Bool?
    let previousAccountId: String?
}

nonisolated struct BrokerResult: Decodable, Sendable {
    let accessToken: String?
    let chatgptAccountID: String?
    let expiresAt: Double?
    let verificationURL: String?
    let userCode: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case chatgptAccountID = "chatgptAccountId"
        case expiresAt
        case verificationURL = "verificationUrl"
        case userCode
    }
}

nonisolated struct BrokerReply: Decodable, Sendable {
    let id: Int
    let result: BrokerResult?
    let error: String?
}

actor CodexBrokerSession {
    enum Error: Swift.Error { case invalidReply, accountChanged, notAuthenticated, timedOut }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()
    private var stopped = false
    private var exited = false
    private var stopDeadline: Task<Void, Never>?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<BrokerResult, any Swift.Error>] = [:]
    /// Ends the reader of the holder's replies (``FileHandle/readyChunks()``); deinit calls it.
    private let stopReading: @Sendable () -> Void

    init(executable: URL, executablePrefix: [String], codexExecutable: URL, home: URL, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try FileManager.checked.createDirectory(at: home, withIntermediateDirectories: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = executablePrefix + ["codex-auth-broker", "--home", home.path, "--codex", codexExecutable.path]
        var environment = ["PATH": inheritedEnvironment["PATH"] ?? "/usr/bin:/bin", "HOME": inheritedEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path]
        for key in ["USER", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = inheritedEnvironment[key] { environment[key] = value }
        }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        // Not `output.bytes.lines`: Foundation reads every `FileHandle.bytes` in the process one
        // at a time, so another session's idle reader (or any other) left this one's replies
        // unread until the 15 s request bound failed them as brokerUnavailable.
        let (chunks, stopReading) = outputPipe.fileHandleForReading.readyChunks()
        self.stopReading = stopReading
        // task-owner: the reader ends at EOF, a failed read, or deinit (stopReading); pending
        // requests fail then.
        Task { [weak self] in
            for await chunk in chunks {
                await self?.consume(chunk)
            }
            await self?.terminatePending()
        }
        process.terminationHandler = { [weak self] _ in
            // task-owner: termination handler reports EOF to the stored reader task.
            Task { await self?.didExit() }
        }
    }

    deinit {
        stopReading()
        stopDeadline?.cancel()
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
    }

    func request(method: String, force: Bool? = nil, previousAccountID: String? = nil) async throws -> BrokerResult {
        try Task.checkCancellation()
        guard !stopped, process.isRunning else { throw Error.invalidReply }
        nextID += 1
        let id = nextID
        let object = BrokerRequest(id: id, method: method, force: force, previousAccountId: previousAccountID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(object) else { throw Error.invalidReply }
        var line = data
        line.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                do {
                    try input.write(contentsOf: line)
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // task-owner: cancellation is sent to the session actor and does not outlive its private child.
            Task { await self.cancel(id) }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // A chunk may hold several replies; the cap is on one reply line (a whole one, or the
        // part of one still waiting for its newline), not on a chunk.
        let limit = 64 * 1024
        func overflow() {
            terminatePending()
            if process.isRunning { process.terminate() }
            buffer.removeAll(keepingCapacity: false)
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            guard newline - buffer.startIndex <= limit else { return overflow() }
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let reply = try? JSONDecoder().decode(BrokerReply.self, from: line),
                  let continuation = pending.removeValue(forKey: reply.id) else { continue }
            if let error = reply.error {
                if error == "codex_auth_account_changed" { continuation.resume(throwing: Error.accountChanged) }
                else if error == "codex_auth_timeout" { continuation.resume(throwing: Error.timedOut) }
                else if error == "codex_auth_unavailable" { continuation.resume(throwing: Error.notAuthenticated) }
                else { continuation.resume(throwing: Error.invalidReply) }
            } else if let result = reply.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: Error.invalidReply)
            }
        }
        if buffer.count > limit { overflow() }
    }

    private func terminatePending() {
        guard !pending.isEmpty else { return }
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: Error.invalidReply) }
    }

    /// The holder releases its inherited credential lock only after its child
    /// exits. Do not allow a replacement to race that cleanup after SIGTERM.
    func shutdown() async {
        stopped = true
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        if exited || !process.isRunning { return }
        if stopDeadline == nil {
            process.terminate()
            stopDeadline = Task { [weak self] in
                // wakeup-allow: one graceful-stop deadline, cancelled on child exit.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await self?.forceStop()
            }
        }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    private func forceStop() {
        // Signal only the child this session launched, never a process group or
        // a discovered PID. Keep waiting for its actual exit before replacement.
        guard !exited, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private func didExit() {
        stopDeadline?.cancel(); stopDeadline = nil
        exited = true
        stopped = true
        // The reader drains final replies before failing remaining requests at
        // EOF; process exit can race the last timeout reply in the pipe.
        let waiting = exitWaiters
        exitWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    private func cancel(_ id: Int) {
        // The holder serializes provider work. Let its bounded in-flight request
        // finish, discard this caller's reply, and preserve other callers.
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

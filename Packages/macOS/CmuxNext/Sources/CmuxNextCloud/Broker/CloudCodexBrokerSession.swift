import CmuxNextCompat
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
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<BrokerResult, any Swift.Error>] = [:]

    init(executable: URL, executablePrefix: [String], codexExecutable: URL, home: URL, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try FileManager.checked.createDirectory(at: home, withIntermediateDirectories: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = executablePrefix + ["codex-auth-broker", "--home", home.path, "--codex", codexExecutable.path]
        var environment = ["PATH": inheritedEnvironment["PATH"] ?? "/usr/bin:/bin", "HOME": inheritedEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path]
        if let user = inheritedEnvironment["USER"] { environment["USER"] = user }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        // task-owner: this reader is bounded by the private broker process and
        // terminates on EOF; pending continuations are failed by terminationHandler.
        Task { [weak self, output = outputPipe.fileHandleForReading] in
            do {
                for try await line in output.bytes.lines {
                    await self?.consume(Data((line + "\n").utf8))
                }
            } catch {
                await self?.terminatePending()
            }
        }
        process.terminationHandler = { [weak self] _ in
            // task-owner: termination handler reports EOF to the stored reader task.
            Task { await self?.terminatePending() }
        }
    }

    deinit {
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
    }

    func request(method: String, force: Bool? = nil, previousAccountID: String? = nil) async throws -> BrokerResult {
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
            Task.detached(priority: .utility) { await self.cancelPending() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 64 * 1024 else {
            terminatePending()
            if process.isRunning { process.terminate() }
            buffer.removeAll(keepingCapacity: false)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let reply = try? JSONDecoder().decode(BrokerReply.self, from: line),
                  let continuation = pending.removeValue(forKey: reply.id) else { continue }
            if let error = reply.error {
                if error == "codex_auth_account_changed" { continuation.resume(throwing: Error.accountChanged) }
                else if error == "codex_auth_unavailable" { continuation.resume(throwing: Error.notAuthenticated) }
                else { continuation.resume(throwing: Error.invalidReply) }
            } else if let result = reply.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: Error.invalidReply)
            }
        }
    }

    private func terminatePending() {
        guard !pending.isEmpty else { return }
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: Error.invalidReply) }
    }

    func shutdown() {
        cancelPending()
        if process.isRunning { process.terminate() }
    }

    private func cancelPending() {
        guard !pending.isEmpty else { return }
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        if process.isRunning { process.terminate() }
    }
}

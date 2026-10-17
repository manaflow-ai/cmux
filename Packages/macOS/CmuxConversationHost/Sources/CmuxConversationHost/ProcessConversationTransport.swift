public import Foundation
public import CmuxConversation
import Darwin
@preconcurrency import Dispatch

/// Launches native provider protocols in a trusted local or SSH workspace.
public struct ProcessConversationTransportFactory: ConversationNativeTransportFactory, Sendable {
    private let executableOverrides: [String: String]

    public init(executableOverrides: [String: String] = [:]) { self.executableOverrides = executableOverrides }

    public func make(provider: ConversationProvider, session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationNativeTransport {
        let name: String
        var providerArguments: [String]
        switch provider {
        case .codex: name = "codex"; providerArguments = ["app-server"]
        case .claudeCode:
            name = "claude"
            providerArguments = ["--print", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose", "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio"]
            if let nativeID = session.providerSessionID { providerArguments += ["--resume", nativeID] }
            else { providerArguments += ["--session-id", session.id.rawValue] }
        case .openCode: throw ConversationProviderError.unsupported("OpenCode requires its HTTP/SSE transport")
        case .unknown: throw ConversationProviderError.unsupported("Unknown provider")
        }
        switch target {
        case .local(let directory):
            let executable = try executable(name: name, provider: provider)
            return try await ProcessConversationTransport.open(executable: executable, arguments: providerArguments, workingDirectory: directory)
        case .ssh(let host, let directory, let arguments):
            // A remote machine has its own installations. Never send a local absolute executable path.
            // Login-shell PATH initialization supports common per-user CLI installations.
            let command = "cd -- \(Self.shellQuote(directory)) && exec \(Self.shellQuote(name)) \(providerArguments.map(Self.shellQuote).joined(separator: " "))"
            let remote = "exec \"${SHELL:-/bin/sh}\" -lc \(Self.shellQuote(command))"
            return try await ProcessConversationTransport.open(executable: "/usr/bin/ssh", arguments: arguments + ["--", host, remote], workingDirectory: nil)
        case .cloud: throw ConversationProviderError.unsupported("This workspace does not expose a native provider transport")
        }
    }

    private func executable(name: String, provider: ConversationProvider) throws -> String {
        if let override = executableOverrides[provider.rawValue] {
            guard FileManager.default.isExecutableFile(atPath: override) else { throw ConversationProviderError.unavailable("Configured provider executable is unavailable") }
            return override
        }
        let candidates = ["\(NSHomeDirectory())/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(NSHomeDirectory())/bin/\(name)"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ConversationProviderError.unavailable("Install \(name) on the selected Mac or SSH host")
        }
        return found
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

/// Owns the process, ordered reads, request continuations and shutdown in one actor.
/// Notifications remain lossless: reaching either bounded buffer closes the connection explicitly.
actor ProcessConversationTransport: ConversationNativeTransport {
    nonisolated let messages: AsyncThrowingStream<ConversationJSONValue, any Error>
    private let continuation: AsyncThrowingStream<ConversationJSONValue, any Error>.Continuation
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var reader: Task<Void, Never>?
    private var reaper: Task<Void, Never>?
    private var closed = false
    private var pending: [String: CheckedContinuation<ConversationJSONValue?, any Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private struct PendingWrite {
        let id: UUID
        let data: Data
        var offset = 0
        let completion: CheckedContinuation<Void, any Error>?
    }
    private var writes: [PendingWrite] = []
    private var queuedWriteBytes = 0
    private var writeSource: (any DispatchSourceWrite)?
    private var writeDeadlines: [UUID: Task<Void, Never>] = [:]
    private let maximumLineBytes = 8 * 1_024 * 1_024
    private let timeout: Duration

    static func open(executable: String, arguments: [String], workingDirectory: String?, timeout: Duration = .seconds(45)) async throws -> ProcessConversationTransport {
        let transport = try ProcessConversationTransport(executable: executable, arguments: arguments, workingDirectory: workingDirectory, timeout: timeout)
        await transport.startReading()
        return transport
    }

    private init(executable: String, arguments: [String], workingDirectory: String?, timeout: Duration) throws {
        let pair = AsyncThrowingStream<ConversationJSONValue, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        messages = pair.stream
        continuation = pair.continuation
        self.timeout = timeout
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true) }
        process.standardInput = stdin
        process.standardOutput = stdout
        // Provider diagnostics can contain credentials or prompts. They are not a UI error channel.
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let flags = fcntl(input.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(input.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ConversationProviderError.unavailable("Could not configure provider input")
        }
        output = stdout.fileHandleForReading
        self.process = process
        do { try process.run() } catch { throw ConversationProviderError.unavailable("The provider process could not start") }
    }

    private func startReading() {
        let chunks = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { chunks.continuation.finish(); return }
            if case .dropped = chunks.continuation.yield(data) {
                chunks.continuation.finish(throwing: ConversationProviderError.unavailable("Provider output exceeded the transport buffer"))
            }
        }
        reader = Task { [weak self] in
            var buffer = Data()
            do {
                for try await chunk in chunks.stream {
                    guard let self, !Task.isCancelled else { return }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer.prefix(upTo: newline))
                        buffer.removeSubrange(...newline)
                        try await self.receive(line)
                    }
                    guard buffer.count <= 8 * 1_024 * 1_024 else { throw ConversationProviderError.malformed("Provider frame exceeds the size limit") }
                }
                if !buffer.isEmpty { try await self?.receive(buffer) }
                await self?.finish(ConversationProviderError.unavailable("Provider connection ended"))
            } catch { await self?.finish(error) }
        }
    }

    func send(_ payload: ConversationJSONValue) async throws -> ConversationJSONValue? {
        try Task.checkCancellation()
        guard !closed else { throw ConversationProviderError.unavailable("Provider connection is closed") }
        var data = try JSONEncoder().encode(payload)
        guard data.count <= maximumLineBytes else { throw ConversationProviderError.rejected("Provider request exceeds the size limit") }
        data.append(10)
        let object = payload.objectValue ?? [:]
        let key: String?
        if object["method"] != nil, let id = object["id"] { key = Self.requestKey(id) }
        else if object["type"]?.stringValue == "control_request", let id = object["request_id"] { key = Self.requestKey(id) }
        else { key = nil }
        guard let key else {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { completion in
                    enqueueWrite(data, completion: completion)
                }
            } onCancel: {
                Task { await self.finish(CancellationError()) }
            }
            return nil
        }
        guard pending[key] == nil else { throw ConversationProviderError.rejected("Duplicate native request identifier") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                pending[key] = waiter
                deadlines[key] = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expire(key)
                }
                enqueueWrite(data, completion: nil)
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    /// Nonblocking writes let reads, cancellation and deadlines continue when a child stops reading stdin.
    /// The bounded FIFO owns complete frames, so concurrent requests cannot interleave their bytes.
    private func enqueueWrite(_ data: Data, completion: CheckedContinuation<Void, any Error>?) {
        guard !closed, writes.count < 64, queuedWriteBytes + data.count <= 16 * 1_024 * 1_024 else {
            let error = ConversationProviderError.unavailable("Provider input buffer is unavailable; delivery is uncertain")
            completion?.resume(throwing: error)
            finish(error)
            return
        }
        let id = UUID()
        writes.append(PendingWrite(id: id, data: data, completion: completion))
        queuedWriteBytes += data.count
        writeDeadlines[id] = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.finish(ConversationProviderError.unavailable("Provider input timed out; delivery is uncertain"))
        }
        drainWrites()
    }

    private func drainWrites() {
        guard !closed, writeSource == nil else { return }
        while !writes.isEmpty {
            let frame = writes[0]
            let count = frame.data.withUnsafeBytes { buffer in
                Darwin.write(input.fileDescriptor, buffer.baseAddress!.advanced(by: frame.offset), buffer.count - frame.offset)
            }
            if count > 0 {
                writes[0].offset += count
                if writes[0].offset == frame.data.count {
                    writes.removeFirst()
                    queuedWriteBytes -= frame.data.count
                    writeDeadlines.removeValue(forKey: frame.id)?.cancel()
                    frame.completion?.resume()
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                let source = DispatchSource.makeWriteSource(fileDescriptor: input.fileDescriptor)
                source.setEventHandler { [weak self] in
                    source.cancel()
                    Task { await self?.writeBecameReady() }
                }
                writeSource = source
                source.resume()
                return
            } else {
                finish(ConversationProviderError.unavailable("Provider write failed; delivery is uncertain"))
                return
            }
        }
    }

    private func writeBecameReady() {
        writeSource?.cancel()
        writeSource = nil
        drainWrites()
    }

    private func receive(_ line: Data) throws {
        guard !closed, !line.isEmpty else { return }
        guard line.count <= maximumLineBytes else { throw ConversationProviderError.malformed("Provider frame exceeds the size limit") }
        let payload: ConversationJSONValue
        do { payload = try JSONDecoder().decode(ConversationJSONValue.self, from: line) }
        catch { throw ConversationProviderError.malformed("Provider returned invalid JSON") }
        let object = payload.objectValue ?? [:]
        var response: ConversationJSONValue?
        var error: ConversationProviderError?
        var key: String?
        if object["method"] == nil, let id = object["id"], object["result"] != nil || object["error"] != nil {
            key = Self.requestKey(id)
            response = object["result"]
            if object["error"] != nil { error = .rejected("The provider rejected the request") }
        } else if object["type"]?.stringValue == "control_response", let value = object["response"]?.objectValue, let id = value["request_id"] {
            key = Self.requestKey(id)
            response = object["response"]
            if value["subtype"]?.stringValue == "error" { error = .rejected("The provider rejected the control request") }
        }
        if let key, let waiter = pending.removeValue(forKey: key) {
            deadlines.removeValue(forKey: key)?.cancel()
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: response) }
            return
        }
        // Unknown/late responses stay inspectable as raw events, never satisfy a different request.
        if case .dropped = continuation.yield(payload) { throw ConversationProviderError.unavailable("Provider events exceeded the transport buffer") }
    }

    private static func requestKey(_ id: ConversationJSONValue) -> String? {
        switch id { case .string(let value): "s:" + value; case .number(let value): "n:" + value; default: nil }
    }

    private func expire(_ key: String) {
        guard pending[key] != nil else { return }
        finish(ConversationProviderError.unavailable("Provider reply timed out; delivery is uncertain"))
    }

    private func cancel(_ key: String) {
        deadlines.removeValue(forKey: key)?.cancel()
        pending.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }

    private func finish(_ error: any Error) {
        guard !closed else { return }
        closed = true
        output.readabilityHandler = nil
        reader?.cancel(); reader = nil
        continuation.finish(throwing: error)
        writeSource?.cancel(); writeSource = nil
        for write in writes { write.completion?.resume(throwing: error) }
        writes.removeAll(); queuedWriteBytes = 0
        for deadline in writeDeadlines.values { deadline.cancel() }
        writeDeadlines.removeAll()
        for waiter in pending.values { waiter.resume(throwing: error) }
        pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        try? input.close()
        try? output.close()
        if process.isRunning {
            process.terminate()
            // Resume an owned stopped child so its pending termination signal can run.
            Darwin.kill(process.processIdentifier, SIGCONT)
            reaper = Task { [self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                killIfStillRunning()
            }
        }
    }

    private func killIfStillRunning() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        reaper = nil
    }

    func close() async { finish(ConversationProviderError.unavailable("Provider connection closed")) }
}

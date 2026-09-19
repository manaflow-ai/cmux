import Darwin
import Foundation

/// Owns one noninteractive shell for a GUI pane, retaining cwd, exports and functions.
///
/// Commands execute serially with closed stdin, bounded output and a deadline.
/// No terminal surface or provider process is needed. Close the session when its
/// pane closes. A stopped or exited shell is recreated at its last confirmed cwd.
public actor GuiShellSession {
    private let environment: [String: String]
    private let shellURL: URL
    private let outputLimit: Int
    private let timeout: Duration
    private var directory: String
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private var pending: (id: String, command: String, marker: Data, continuation: CheckedContinuation<GuiShellResult, Error>)?
    private var buffer = Data()
    private var completed: [String: (command: String, result: GuiShellResult)] = [:]
    private var completedOrder: [String] = []

    /// Creates a shell session without starting a process.
    /// - Parameters:
    ///   - workingDirectory: Initial local directory, captured from the owning pane.
    ///   - environment: Environment for shell commands, including cmux routing.
    ///   - shellURL: Shell implementing POSIX eval and printf; defaults to zsh.
    ///   - outputLimit: Maximum retained output bytes for each completed command.
    ///   - timeout: Maximum time for a command before its process tree is stopped.
    public init(
        workingDirectory: String,
        environment: [String: String],
        shellURL: URL = URL(fileURLWithPath: "/bin/zsh"),
        outputLimit: Int = 64 * 1024,
        timeout: Duration = .seconds(60)
    ) {
        directory = workingDirectory
        self.environment = environment
        self.shellURL = shellURL
        self.outputLimit = max(1024, outputLimit)
        self.timeout = timeout
    }

    /// Runs a command in this pane's shell, or returns a completed retry's result.
    /// - Parameters:
    ///   - command: Literal shell source supplied by the user.
    ///   - requestID: Stable identity for deduplicating retries.
    /// - Returns: Output, exit status and cwd reported by the shell.
    /// - Throws: A lifecycle or process-launch error. Nonzero command exits are results.
    public func execute(command: String, requestID: String) async throws -> GuiShellResult {
        guard !closed else { throw GuiShellError.closed }
        guard !command.isEmpty, command.utf8.count <= 64 * 1024 else { throw GuiShellError.invalidRequest }
        if let previous = completed[requestID] {
            guard previous.command == command else { throw GuiShellError.invalidRequest }
            return previous.result
        }
        guard pending == nil else { throw GuiShellError.busy }
        try Task.checkCancellation()
        try startIfNeeded()
        let token = UUID().uuidString
        let marker = Data(("\0" + token + "\0").utf8)
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "builtin eval \(quoted) </dev/null\nbuiltin printf '\\000\(token)\\000%d\\000%s\\000' \"$?\" \"$PWD\"\n"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (requestID, command, marker, continuation)
                buffer.removeAll(keepingCapacity: true)
                deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.stop(requestID: requestID, error: .timedOut)
                }
                let writer = input!
                // Pipe writes may block; keep them away from the actor's executor.
                Task.detached(priority: .utility) { [weak self] in
                    do { try writer.write(contentsOf: Data(script.utf8)) }
                    catch { await self?.stop(requestID: requestID, error: .terminated) }
                }
            }
        } onCancel: {
            Task { await self.stop(requestID: requestID, error: .cancelled) }
        }
    }

    /// Stops only the identified in-flight command; later commands can start a new shell.
    /// - Parameter requestID: Request to cancel, preventing stale cancellation.
    public func cancel(requestID: String) { stop(requestID: requestID, error: .cancelled) }

    /// Closes the shell and rejects pending or future commands.
    public func close() {
        closed = true
        if let pending { stop(requestID: pending.id, error: .closed) }
        else { terminateProcess() }
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = shellURL
        process.arguments = ["-f", "-s"]
        var commandEnvironment = environment
        commandEnvironment["TERM"] = "dumb"
        commandEnvironment["NO_COLOR"] = "1"
        commandEnvironment["CLICOLOR"] = "0"
        process.environment = commandEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        self.process = process
        input = stdin.fileHandleForWriting
        generation = UUID()
        let generation = generation
        let output = stdout.fileHandleForReading
        reader = Task.detached(priority: .utility) { [weak self] in
            // One blocking pipe reader per shell, with backpressure at each actor hop.
            defer { try? output.close() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                await self?.receive(count > 0 ? Data(bytes.prefix(count)) : Data(), generation: generation)
                if count <= 0 { return }
            }
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == self.generation else { return }
        guard !data.isEmpty else {
            if let pending { stop(requestID: pending.id, error: .terminated) }
            return
        }
        guard let pending else { return }
        buffer.append(data)
        if let range = buffer.range(of: pending.marker) {
            let fields = buffer[range.upperBound...].split(separator: 0, omittingEmptySubsequences: false)
            if fields.count >= 3, let exitCode = Int32(String(decoding: fields[0], as: UTF8.self)) {
                let cwd = String(decoding: fields[1], as: UTF8.self)
                let result = GuiShellResult(
                    output: String(decoding: buffer[..<range.lowerBound].suffix(outputLimit), as: UTF8.self),
                    exitCode: exitCode,
                    workingDirectory: cwd
                )
                directory = cwd
                self.pending = nil
                deadline?.cancel()
                deadline = nil
                buffer.removeAll(keepingCapacity: true)
                completed[pending.id] = (pending.command, result)
                completedOrder.append(pending.id)
                if completedOrder.count > 32 { completed.removeValue(forKey: completedOrder.removeFirst()) }
                pending.continuation.resume(returning: result)
                return
            }
        }
        if buffer.count > outputLimit + 16 * 1024 { buffer = Data(buffer.suffix(outputLimit + 16 * 1024)) }
    }

    private func stop(requestID: String, error: GuiShellError) {
        guard let pending, pending.id == requestID else { return }
        self.pending = nil
        deadline?.cancel()
        deadline = nil
        terminateProcess()
        pending.continuation.resume(throwing: error)
    }

    private func terminateProcess() {
        generation = UUID()
        if let process { GuiShellProcessTree().terminate(process) }
        process = nil
        try? input?.close()
        input = nil
        reader?.cancel()
        reader = nil
        buffer.removeAll()
    }
}

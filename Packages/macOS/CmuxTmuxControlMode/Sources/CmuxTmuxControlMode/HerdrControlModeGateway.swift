public import Foundation
public import CmuxTerminalCore

/// A direct, writable Herdr terminal stream. Herdr remains the owner of the
/// terminal emulator and its process. This gateway transports ANSI frames and
/// input commands to a local manual-IO surface.
public final class HerdrControlModeGateway: TerminalSessionSource, @unchecked Sendable {
    private let sessionName: String
    private let target: String
    private let remoteDestination: String?
    private let herdrExecutablePath: String
    private let environment: [String: String]?

    private let queue = DispatchQueue(label: "com.cmux.herdr-control-mode.gateway")
    private var parser = HerdrControlModeParser()
    private weak var delegate: (any TerminalSessionSourceDelegate)?
    private var eventDelivery: TerminalSessionSourceEventDelivery?
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var inputWriter: ControlModeProcessInputWriter?
    private var stdoutReader: ControlModeProcessOutputReader?
    private var stderrReader: ControlModeProcessOutputReader?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var launched = false
    private var finished = false
    private var stopping = false
    private var stopRequested = false
    private var stopTask: Task<Void, Never>?
    private var sawFrame = false
    private var lastFrameSequence: UInt64?
    private var didReportResizePolicy = false
    private var stdoutEnded = false
    private var stderrEnded = false
    private var terminationStatus: Int32?
    private var transportFailureReason: String?
    private var stderrTail = ""
    private var currentSize = TerminalSize(columns: 80, rows: 24)
    /// A resize can arrive before the process launch block runs. Keep the
    /// newest full metric tuple so the CLI handshake and the first JSON
    /// resize use the same geometry.
    private var pendingSize: TerminalSize?
    private var pendingWrites: [Data] = []
    private var pendingWriteBytes = 0
    private let sleep: @Sendable (Duration) async throws -> Void

    private static let maxStderrBytes = 8 * 1024
    private static let maximumInputBytesPerRecord = 64 * 1024
    private static let maximumPendingWriteBytes = 8 * 1024 * 1024
    private static let releaseTimeout = Duration.seconds(2)

    public var displayName: String { "herdr: \(sessionName):\(target)" }

    public var supportsSemanticScroll: Bool { true }

    public init(
        sessionName: String,
        target: String,
        herdrExecutablePath: String,
        remoteDestination: String? = nil,
        environment: [String: String]? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.sessionName = sessionName
        self.target = target
        self.herdrExecutablePath = herdrExecutablePath
        self.remoteDestination = remoteDestination
        self.environment = environment
        self.sleep = sleep
    }

    public func start(initialSize: TerminalSize, delegate: any TerminalSessionSourceDelegate) {
        queue.async { [self] in
            guard !launched, !stopRequested else { return }
            launched = true
            let hadPendingSize = pendingSize != nil
            let effectiveSize = pendingSize ?? initialSize
            pendingSize = nil
            currentSize = effectiveSize
            self.delegate = delegate
            self.eventDelivery = TerminalSessionSourceEventDelivery(delegate: delegate)

            // `stop()` may win the race with process creation. The source
            // must still close its lifecycle once a delegate exists, rather
            // than silently dropping the start and stranding the surface.
            guard !stopRequested else {
                finish(termination: .ended(reason: nil))
                return
            }
            configureProcess(initialSize: effectiveSize)

            // A pre-launch resize is held as state, not as a wire record. Put
            // the final size before any input admitted during startup. This
            // is required for deterministic mouse coordinates and avoids a
            // stale initial grid; it also coalesces a drag that happened while
            // the process was being created.
            if hadPendingSize || !pendingWrites.isEmpty || effectiveSize.hasCellMetrics {
                let record = Self.resizeLine(effectiveSize)
                pendingWrites.insert(record, at: 0)
                pendingWriteBytes += record.count
            }

            guard let stdoutReader = ControlModeProcessOutputReader(
                readingFrom: stdoutPipe.fileHandleForReading,
                label: "com.cmux.herdr-control-mode.stdout.\(UUID().uuidString)",
                maxPendingChunks: 4096,
                maxPendingBytes: 32 * 1024 * 1024,
                onOverflow: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure("herdr control output exceeded its bounded buffer")
                    }
                }
            ) else {
                finish(termination: .failed(reason: "failed to attach Herdr control output reader"))
                return
            }
            guard let stderrReader = ControlModeProcessOutputReader(
                readingFrom: stderrPipe.fileHandleForReading,
                label: "com.cmux.herdr-control-mode.stderr.\(UUID().uuidString)",
                maxPendingChunks: 256,
                maxPendingBytes: 1024 * 1024,
                onOverflow: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure("herdr diagnostics exceeded its bounded buffer")
                    }
                }
            ) else {
                stdoutReader.close()
                finish(termination: .failed(reason: "failed to attach Herdr diagnostics reader"))
                return
            }
            self.stdoutReader = stdoutReader
            self.stderrReader = stderrReader
            let inputWriter = ControlModeProcessInputWriter(
                label: "com.cmux.herdr-control-mode.stdin.\(UUID().uuidString)",
                maxPendingBytes: 8 * 1024 * 1024,
                onFailure: { [weak self] reason in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure(reason)
                    }
                }
            )
            self.inputWriter = inputWriter
            inputWriter.attach(to: stdinPipe.fileHandleForWriting)
            flushPendingWrites()

            stdoutTask = Task { [weak self, stdoutReader] in
                for await chunk in stdoutReader.stream {
                    guard let self else {
                        stdoutReader.release(chunk)
                        return
                    }
                    // Keep one chunk in flight. Awaiting the protocol queue
                    // gives the reader real backpressure without using a
                    // queue as a mutable-state lock.
                    await self.enqueueOnProtocolQueue { [weak self, stdoutReader, chunk] in
                        defer { stdoutReader.release(chunk) }
                        guard let self, !self.finished else { return }
                        self.apply(self.parser.consume(Array(chunk)))
                    }
                }
                if let self {
                    await self.enqueueOnProtocolQueue { [weak self] in
                        guard let self else { return }
                        self.apply(self.parser.finish())
                        self.stdoutDidEnd()
                    }
                }
            }
            stderrTask = Task { [weak self, stderrReader] in
                for await chunk in stderrReader.stream {
                    guard let self else {
                        stderrReader.release(chunk)
                        return
                    }
                    await self.enqueueOnProtocolQueue { [weak self, stderrReader, chunk] in
                        defer { stderrReader.release(chunk) }
                        guard let self else { return }
                        self.appendStderr(chunk)
                    }
                }
                if let self {
                    await self.enqueueOnProtocolQueue { [weak self] in
                        guard let self else { return }
                        self.stderrEnded = true
                        self.finishAfterTransportDrainIfReady()
                    }
                }
            }

            process.terminationHandler = { [weak self, stdoutReader, stderrReader] process in
                // A termination callback can beat the final frame in either
                // pipe. The readers drain the descriptors before the gateway
                // declares transport loss.
                stdoutReader.processDidExit()
                stderrReader.processDidExit()
                guard let self else { return }
                let status = process.terminationStatus
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.terminationStatus = status
                    self.finishAfterTransportDrainIfReady()
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutReader.close()
                stderrReader.close()
                finish(termination: .failed(reason: "failed to launch herdr: \(error.localizedDescription)"))
                return
            }
            // The child owns the inherited descriptor and the shared writer
            // owns its duplicate. Remove the parent's extra reference so EOF
            // is a real lifecycle signal when the writer closes.
            try? stdinPipe.fileHandleForWriting.close()
            // The readers classify completion from EOF, not only from
            // Process.terminationHandler. Retaining these parent write ends
            // would make every otherwise clean Herdr exit wait indefinitely.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
    }

    public func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            // Keep pre-launch input in the bounded protocol FIFO. The writer
            // is attached asynchronously, so dropping this data creates a
            // race where the first keystrokes disappear.
            guard !finished, !stopping else { return }
            // JSONL is the wire protocol. Bound each record so a paste cannot
            // monopolize the writer queue or exceed a peer's line limit. The
            // records remain FIFO, so splitting is invisible to the terminal.
            for line in Self.inputLines(bytes: bytes) {
                write(line)
            }
        }
    }

    public func resize(_ size: TerminalSize) {
        queue.async { [self] in
            guard !finished, !stopping else { return }
            currentSize = size
            if !launched {
                pendingSize = size
                return
            }
            write(Self.resizeLine(size))
        }
    }

    public func sendScroll(_ command: TerminalScrollCommand) {
        queue.async { [self] in
            guard !finished, !stopping else { return }
            write(Self.scrollLine(command))
        }
    }

    /// Herdr's page-key path uses the visible viewport height, matching its
    /// native attach client. The caller supplies names only for unmodified
    /// PageUp/PageDown keys.
    public func sendNamedKey(_ name: String) {
        let direction: TerminalScrollCommand.Direction
        switch name {
        case "PPage": direction = .up
        case "NPage": direction = .down
        default: return
        }
        queue.async { [self] in
            guard !finished, !stopping else { return }
            guard let command = TerminalScrollCommand(
                direction: direction,
                lines: max(1, currentSize.rows - 1),
                source: .pageKey
            ) else { return }
            write(Self.scrollLine(command))
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !finished, !stopping else { return }
            stopRequested = true
            guard launched else { return }
            // Herdr defines release as the ownership operation. The process
            // signal is a bounded transport fallback after the release has
            // been sent. Waiting lets the server publish terminal.closed.
            stopping = true
            write(Data(#"{"type":"terminal.release"}"#.utf8) + Data([0x0A]))
            stopTask?.cancel()
            let sleep = sleep
            stopTask = Task { [weak self] in
                do {
                    try await sleep(Self.releaseTimeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.stopping, !self.finished else { return }
                    self.transportFailureReason = self.transportFailureReason ?? "herdr release timed out"
                    self.process.terminate()
                }
            }
        }
    }

    private func configureProcess(initialSize: TerminalSize) {
        if let remoteDestination {
            // Herdr's `--remote` flag is only for launching its full client
            // UI. It is rejected when combined with a subcommand, including
            // `terminal session control`. A control stream is already a
            // byte-transparent protocol, so run the control subcommand on
            // the remote host and use SSH only as its stdin/stdout transport.
            // `-T` is required: allocating a pty would add terminal
            // negotiation bytes to the JSONL stream and can line-buffer or
            // rewrite protocol data.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.remoteArguments(
                destination: remoteDestination,
                sessionName: sessionName,
                target: target,
                size: initialSize
            )
        } else {
            process.executableURL = URL(fileURLWithPath: herdrExecutablePath)
            process.arguments = Self.localArguments(
                sessionName: sessionName,
                target: target,
                size: initialSize
            )
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr is diagnostic text, not part of Herdr's JSON-lines protocol.
        process.standardError = stderrPipe
        if let environment {
            // Environment values passed by Harbor are overrides. Preserve the
            // inherited HOME, PATH, locale, and authentication variables that
            // the Herdr client needs when the caller supplies only one key.
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, override in override
            }
        }
    }

    private func apply(_ events: [HerdrControlModeEvent]) {
        guard !finished else { return }
        for event in events {
            switch event {
            case let .frame(bytes, sequence, _, _, full):
                // A sequence is optional for compatibility with early Herdr
                // clients. When present, it is the stream's ordering proof;
                // accepting a duplicate or older frame would apply stale
                // terminal state after a resize/replay.
                if let sequence {
                    if let lastFrameSequence, sequence <= lastFrameSequence {
                        finish(termination: .failed(reason: "herdr frame sequence is invalid"))
                        break
                    }
                    lastFrameSequence = sequence
                }
                if !didReportResizePolicy {
                    didReportResizePolicy = true
                    enqueueDelegateEvent(.resizePolicy(.preserveScreen))
                }
                if !sawFrame || full {
                    sawFrame = true
                    let replacement = TerminalSessionSnapshot.replacing(bytes)
                    enqueueDelegateEvent(.snapshot(replacement))
                } else {
                    guard !bytes.isEmpty else { continue }
                    enqueueDelegateEvent(.output(bytes))
                }
            case let .closed(reason):
                finish(termination: .ended(reason: reason ?? "herdr terminal closed"))
            case let .protocolError(reason):
                finish(termination: .failed(reason: reason))
            }
            if finished { break }
        }
    }

    private func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.utf8.count > Self.maxStderrBytes {
            stderrTail = String(decoding: Array(stderrTail.utf8.suffix(Self.maxStderrBytes)), as: UTF8.self)
        }
    }

    private func stdoutDidEnd() {
        guard !stdoutEnded else { return }
        stdoutEnded = true
        guard !finished else { return }
        if terminationStatus == nil {
            if !stopping { handleTransportFailure("herdr control stream closed") }
        } else {
            finishAfterTransportDrainIfReady()
        }
    }

    private func handleTransportFailure(_ reason: String) {
        guard !finished else { return }
        transportFailureReason = transportFailureReason ?? reason
        if process.isRunning {
            process.terminate()
        }
        finishAfterTransportDrainIfReady()
    }

    private func finishAfterTransportDrainIfReady() {
        guard !finished, terminationStatus != nil, stdoutEnded, stderrEnded else { return }
        let termination: TerminalSessionTermination
        if let transportFailureReason {
            termination = .failed(reason: transportFailureReason)
        } else if stopping {
            // `terminal.release` is a client detach operation. Some Herdr
            // versions close the JSONL stream without sending
            // `terminal.closed`, and the fallback signal can produce a
            // non-zero status. The caller initiated that shutdown, so it is
            // still a clean detach unless a transport failure was recorded
            // above.
            termination = .ended(reason: nil)
        } else if terminationStatus != 0 {
            let diagnostic = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            termination = .failed(
                reason: diagnostic.isEmpty ? "herdr exited (\(terminationStatus!))" : diagnostic
            )
        } else {
            termination = .failed(reason: "herdr control stream ended without a terminal.closed record")
        }
        finish(termination: termination)
    }

    private func finish(termination: TerminalSessionTermination) {
        guard !finished else { return }
        finished = true
        let delivery = eventDelivery
        let delegate = self.delegate
        closeTransport()
        if let delivery {
            delivery.finish(termination)
        } else {
            Task { @MainActor in
                delegate?.controlModeSession(didTerminate: termination)
            }
        }
    }

    /// The protocol queue is the single producer for the delivery lane. A
    /// dropped frame would make the local surface disagree with Herdr's
    /// authoritative viewport, so a full lane fails the attachment visibly.
    private func enqueueDelegateEvent(_ event: TerminalSessionSourceEventDelivery.Event) {
        guard !finished else { return }
        guard let eventDelivery else { return }
        guard eventDelivery.enqueue(event) else {
            handleTransportFailure("herdr delegate delivery exceeded its bounded buffer")
            return
        }
    }

    private func closeTransport() {
        process.terminationHandler = nil
        stopTask?.cancel()
        stopTask = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        stdoutReader?.close()
        stderrReader?.close()
        stdoutReader = nil
        stderrReader = nil
        inputWriter?.close()
        inputWriter = nil
        pendingWrites.removeAll(keepingCapacity: false)
        pendingWriteBytes = 0
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ data: Data) {
        guard !finished, !data.isEmpty else { return }
        guard launched, let inputWriter else {
            guard data.count <= Self.maximumPendingWriteBytes - pendingWriteBytes else {
                if !launched {
                    finish(termination: .failed(reason: "herdr input exceeded its bounded pre-launch buffer"))
                } else {
                    handleTransportFailure("herdr input exceeded its bounded pre-launch buffer")
                }
                return
            }
            pendingWrites.append(data)
            pendingWriteBytes += data.count
            return
        }
        guard inputWriter.enqueue(data) else {
            handleTransportFailure("herdr input writer is unavailable")
            return
        }
    }

    private func flushPendingWrites() {
        guard let inputWriter else { return }
        let writes = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        pendingWriteBytes = 0
        for data in writes {
            guard inputWriter.enqueue(data) else {
                handleTransportFailure("herdr input writer is unavailable")
                return
            }
        }
    }

    /// Delivers one event on the protocol executor and suspends the producer
    /// until that event is complete. This continuation is the bounded
    /// backpressure seam; the dispatch queue remains an event executor rather
    /// than a synchronous state mutex.
    private func enqueueOnProtocolQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                operation()
            }
        }
    }

    static func localArguments(
        sessionName: String,
        target: String,
        size: TerminalSize
    ) -> [String] {
        [
            "--session", sessionName,
            "terminal", "session", "control", target,
            "--takeover",
            "--cols", String(max(1, size.columns)),
            "--rows", String(max(1, size.rows)),
        ]
    }

    /// Build the SSH argv for a remote Herdr control stream. OpenSSH accepts
    /// the remote command as one argument and lets the remote login shell parse
    /// it, so every field is quoted before composition. The command deliberately
    /// invokes the subcommand on the remote host rather than using Herdr's
    /// full-client `--remote` mode, which cannot carry control subcommands.
    static func remoteArguments(
        destination: String,
        sessionName: String,
        target: String,
        size: TerminalSize
    ) -> [String] {
        let remoteCommand = ([
            "herdr",
            "--session", shellQuote(sessionName),
            "terminal", "session", "control", shellQuote(target),
            "--takeover",
            "--cols", shellQuote(String(max(1, size.columns))),
            "--rows", shellQuote(String(max(1, size.rows))),
        ]).joined(separator: " ")
        return [
            "-T",
            "-o", "EscapeChar=none",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "--", destination, remoteCommand,
        ]
    }

    /// Quote one value for the remote login shell. The SSH API accepts the
    /// command as a single string, so this is the only shell boundary in the
    /// remote control path. Herdr session and terminal identifiers are
    /// validated by Herdr, but quoting remains required for spaces and for a
    /// future identifier policy change.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func inputLine(bytes: [UInt8]) -> Data {
        var object = Data("{\"type\":\"terminal.input\",\"bytes\":\"".utf8)
        object.append(Data(bytes).base64EncodedString().data(using: .utf8)!)
        object.append(Data("\"}\n".utf8))
        return object
    }

    static func inputLines(
        bytes: [UInt8],
        maximumBytesPerRecord: Int = maximumInputBytesPerRecord
    ) -> [Data] {
        guard !bytes.isEmpty else { return [] }
        let chunkSize = max(1, maximumBytesPerRecord)
        return stride(from: 0, to: bytes.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, bytes.count)
            return inputLine(bytes: Array(bytes[start..<end]))
        }
    }

    private static func resizeLine(_ size: TerminalSize) -> Data {
        var fields = [
            "\"type\":\"terminal.resize\"",
            "\"cols\":\(max(1, size.columns))",
            "\"rows\":\(max(1, size.rows))",
        ]
        if size.hasCellMetrics {
            fields.append("\"cell_width_px\":\(size.cellWidthPixels)")
            fields.append("\"cell_height_px\":\(size.cellHeightPixels)")
        }
        return Data(("{" + fields.joined(separator: ",") + "}\n").utf8)
    }

    static func scrollLine(_ command: TerminalScrollCommand) -> Data {
        var fields = [
            "\"type\":\"terminal.scroll\"",
            "\"direction\":\"\(command.direction.rawValue)\"",
            "\"lines\":\(command.lines)",
            "\"source\":\"\(command.source.rawValue)\"",
        ]
        if let column = command.column { fields.append("\"column\":\(column)") }
        if let row = command.row { fields.append("\"row\":\(row)") }
        fields.append("\"modifiers\":\(command.modifiers)")
        return Data(("{" + fields.joined(separator: ",") + "}\n").utf8)
    }

    /// Resolve the installed Herdr CLI without using a shell lookup. The
    /// explicit Homebrew paths cover app launches with a minimal environment;
    /// PATH is still searched for custom installs.
    public static func resolveHerdrExecutable(pathEnvironment: String? = nil) -> String? {
        let fileManager = FileManager.default
        var candidates = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/usr/bin/herdr"]
        let searchPath = pathEnvironment ?? ProcessInfo.processInfo.environment["PATH"]
        if let searchPath {
            candidates.append(contentsOf: searchPath.split(separator: ":").map { "\($0)/herdr" })
        }
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }
}

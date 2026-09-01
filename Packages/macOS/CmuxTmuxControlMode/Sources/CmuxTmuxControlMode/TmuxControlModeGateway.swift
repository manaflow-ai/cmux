import Foundation

/// A process-backed tmux control-mode session. It owns only the client
/// transport. tmux owns the shell and pane process, while
/// ``TmuxControlModeSessionCore`` owns protocol state and command correlation.
/// The gateway forwards the resulting bytes to a manual-IO surface.
public final class TmuxControlModeGateway: TerminalSessionSource, @unchecked Sendable {
    private let target: TmuxAttachTarget
    private let tmuxExecutablePath: String
    private let remoteDestination: String?
    private let workingDirectory: String?
    private let environment: [String: String]?

    private let queue = DispatchQueue(label: "com.cmux.tmux-control-mode.gateway")
    private var core: TmuxControlModeSessionCore
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
    private var stdoutEnded = false
    private var stderrEnded = false
    private var terminationStatus: Int32?
    private var transportFailureReason: String?
    private var stderrTail = ""
    private var initialSize: TerminalSize?
    private var didStartCore = false
    private let sleep: @Sendable (Duration) async throws -> Void

    private static let maxStderrBytes = 8 * 1024
    private static let detachTimeout = Duration.seconds(2)

    public var displayName: String {
        switch target {
        case .mostRecent: return "tmux"
        case let .session(name): return "tmux: \(name)"
        case let .pane(name, _, paneID): return "tmux: \(name):%\(paneID)"
        }
    }

    public init(
        target: TmuxAttachTarget,
        tmuxExecutablePath: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        remoteDestination: String? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.target = target
        self.tmuxExecutablePath = tmuxExecutablePath
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.remoteDestination = remoteDestination
        self.sleep = sleep
        self.core = TmuxControlModeSessionCore(
            targetPaneID: target.explicitPaneID,
            targetWindowID: target.explicitWindowID,
            // Both transports run the application form of control mode
            // (`-CC`). Local tmux gets a real pty from `script(1)` and SSH
            // gets one from `-tt`, so the DCS envelope is part of every
            // production stream and must be parsed consistently.
            stripDCSFraming: true
        )
    }

    public func start(initialSize: TerminalSize, delegate: any TerminalSessionSourceDelegate) {
        queue.async { [self] in
            guard !launched, !stopRequested else { return }
            launched = true
            self.delegate = delegate
            self.eventDelivery = TerminalSessionSourceEventDelivery(delegate: delegate)
            self.initialSize = initialSize
            self.didStartCore = false

            // `stop()` can be requested before the asynchronous launch block
            // runs. Create the delivery lane first, then report a clean
            // cancelled attachment instead of leaving the surface in a
            // permanent connecting state.
            guard !stopRequested else {
                finish(termination: .ended(reason: nil))
                return
            }
            configureProcess()

            guard let stdoutReader = ControlModeProcessOutputReader(
                readingFrom: stdoutPipe.fileHandleForReading,
                label: "com.cmux.tmux-control-mode.stdout.\(UUID().uuidString)",
                maxPendingChunks: 4096,
                maxPendingBytes: 32 * 1024 * 1024,
                onOverflow: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure("tmux control output exceeded its bounded buffer")
                    }
                }
            ) else {
                finish(termination: .failed(reason: "failed to attach tmux control output reader"))
                return
            }
            guard let stderrReader = ControlModeProcessOutputReader(
                readingFrom: stderrPipe.fileHandleForReading,
                label: "com.cmux.tmux-control-mode.stderr.\(UUID().uuidString)",
                maxPendingChunks: 256,
                maxPendingBytes: 1024 * 1024,
                onOverflow: { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure("tmux diagnostics exceeded its bounded buffer")
                    }
                }
            ) else {
                stdoutReader.close()
                finish(termination: .failed(reason: "failed to attach tmux diagnostics reader"))
                return
            }
            self.stdoutReader = stdoutReader
            self.stderrReader = stderrReader
            let inputWriter = ControlModeProcessInputWriter(
                label: "com.cmux.tmux-control-mode.stdin.\(UUID().uuidString)",
                maxPendingBytes: 8 * 1024 * 1024,
                onFailure: { [weak self] reason in
                    self?.queue.async { [weak self] in
                        self?.handleTransportFailure(reason)
                    }
                }
            )
            self.inputWriter = inputWriter
            inputWriter.attach(to: stdinPipe.fileHandleForWriting)

            stdoutTask = Task { [weak self, stdoutReader] in
                for await chunk in stdoutReader.stream {
                    guard let self else {
                        stdoutReader.release(chunk)
                        return
                    }
                    // Await one bounded delivery before reading the next
                    // chunk. This is backpressure through an async
                    // continuation, not a queue used as a state mutex.
                    await self.enqueueOnProtocolQueue { [weak self, stdoutReader, chunk] in
                        defer { stdoutReader.release(chunk) }
                        guard let self, !self.finished else { return }
                        self.consumeControlBytes(Array(chunk))
                    }
                }
                if let self {
                    await self.enqueueOnProtocolQueue { [weak self] in
                        guard let self else { return }
                        self.apply(self.core.finishStream())
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
                // Termination and pipe EOF are separate events. Ask both
                // readers to drain their kernel buffers before the gateway
                // classifies the transport as ended.
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
                finish(termination: .failed(reason: "failed to launch tmux: \(error.localizedDescription)"))
                return
            }

            // The child now owns its inherited stdin descriptor. The writer
            // owns its duplicate. Closing the parent's original endpoint is
            // required so writer shutdown can deliver EOF instead of leaving
            // an extra reference that keeps the child waiting forever.
            try? stdinPipe.fileHandleForWriting.close()
            // EOF on stdout and stderr is the transport completion signal. The
            // parent must release its pipe write ends immediately after launch
            // or the readers can never observe the child closing them.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()

            // The first client command is sent by `consumeControlBytes` after
            // tmux has emitted its attach response. This is the pty setup
            // boundary for `-CC`; sending earlier would allow `script(1)` to
            // echo command bytes before `stty raw -echo` is active.
        }
    }

    public func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            // The core owns a bounded pre-handshake FIFO. Do not drop input
            // merely because Process.run is still establishing the pty.
            guard !finished, !stopping else { return }
            apply(core.sendInput(bytes))
        }
    }

    public func sendNamedKey(_ name: String) {
        queue.async { [self] in
            guard !finished, !stopping else { return }
            apply(core.sendNamedKey(name))
        }
    }

    public func resize(_ size: TerminalSize) {
        queue.async { [self] in
            // Keep the latest size even when the child has not launched yet;
            // `start` consumes it for the first refresh-client claim.
            guard !finished, !stopping else { return }
            apply(core.resize(size))
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !finished, !stopping else { return }
            stopRequested = true
            guard launched else { return }
            // `detach-client` is the control-mode lifecycle operation. The
            // process signal below is only a bounded fallback if tmux does not
            // close the client after accepting the command. Waiting avoids
            // racing the detach command with SIGTERM.
            stopping = true
            writeToGateway(Array("detach-client\n".utf8))
            stopTask?.cancel()
            let sleep = sleep
            stopTask = Task { [weak self] in
                do {
                    try await sleep(Self.detachTimeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.stopping, !self.finished else { return }
                    self.transportFailureReason = self.transportFailureReason ?? "tmux detach timed out"
                    self.process.terminate()
                }
            }
        }
    }

    // MARK: Process setup and stream lifecycle

    private func configureProcess() {
        if let remoteDestination {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // The SSH client forwards its local TERM value to the remote
            // command. `xterm-ghostty` is not installed on many hosts, so a
            // control client can fail before tmux emits its first protocol
            // fence. Use the portable terminfo that the existing Harbor SSH
            // attach path uses as well.
            let tmuxCommand = ([
                "env", "-u", "TMUX", "-u", "TMUX_PANE",
                "TERM=xterm-256color", "tmux", "-u", "-CC",
            ] + target.tmuxArguments)
                .map(Self.shellQuote)
                .joined(separator: " ")
            // Establish the remote pty's byte contract before tmux enters
            // application control mode. `-tt` is intentional because -CC
            // requires a tty. Disable OpenSSH escape processing so pane bytes
            // cannot be interpreted as client commands.
            let remoteCommand = "stty raw -echo 2>/dev/null || true; exec \(tmuxCommand)"
            process.arguments = [
                "-tt", "-o", "EscapeChar=none", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
                remoteDestination, remoteCommand,
            ]
        } else {
            // `-CC` is the application form of tmux control mode. It requires
            // a tty, so launch it through macOS `script(1)`, which allocates a
            // pty while leaving this gateway's parent side as ordinary pipes.
            // Falling back to single `-C` would use tmux's testing mode and
            // silently change terminal-attribute semantics in production.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = Self.localControlModeArguments(
                tmuxExecutablePath: tmuxExecutablePath,
                target: target
            )
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr is a diagnostic channel, never part of the control protocol.
        // Merging it into stdout can turn a launch error into a fake tmux line.
        process.standardError = stderrPipe
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        // `Process.environment` replaces the inherited environment. Preserve
        // HOME, PATH, locale, SSH_AUTH_SOCK, and user tmux settings, then
        // remove tmux's nesting markers. A Harbor client selects its target
        // explicitly; inheriting `TMUX`/`TMUX_PANE` would let an outer client
        // silently redirect `attach` to the wrong server or pane.
        var launchEnvironment = ProcessInfo.processInfo.environment
        if let environment {
            launchEnvironment.merge(environment) { _, override in override }
        }
        launchEnvironment.removeValue(forKey: "TMUX")
        launchEnvironment.removeValue(forKey: "TMUX_PANE")
        process.environment = launchEnvironment
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
            if !stopping { handleTransportFailure("tmux control stream closed") }
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
            // A requested detach is a clean client lifecycle result even if
            // the pty wrapper reports a non-zero status while closing.
            termination = .ended(reason: nil)
        } else if terminationStatus != 0 {
            let diagnostic = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            termination = .failed(
                reason: diagnostic.isEmpty ? "tmux exited (\(terminationStatus!))" : diagnostic
            )
        } else {
            // A zero status without a protocol exit event is not enough to
            // prove the pane ended. The core may already have finished on a
            // `%exit`; reaching this branch means the stream ended first.
            termination = .failed(reason: "tmux control stream ended without an exit event")
        }
        switch termination {
        case let .ended(reason):
            apply(core.gatewayExited(reason: reason))
        case let .failed(reason):
            apply(core.gatewayFailed(reason: reason))
        }
    }

    // MARK: Effect application (always on `queue`)

    private func consumeControlBytes(_ bytes: [UInt8]) {
        guard !finished else { return }
        apply(core.consume(bytes))
        guard !finished, !didStartCore,
              core.attachHandshakeComplete,
              let initialSize else { return }
        didStartCore = true
        apply(core.start(initialSize: initialSize))
    }

    private func apply(_ effects: [TmuxControlModeSessionCore.Effect]) {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case let .write(bytes):
                writeToGateway(bytes)
            case let .snapshot(bytes):
                enqueueDelegateEvent(.snapshot(bytes))
            case let .output(bytes):
                enqueueDelegateEvent(.output(bytes))
            case let .resizePolicy(policy):
                enqueueDelegateEvent(.resizePolicy(policy))
            case let .ended(reason):
                finish(termination: .ended(reason: reason))
            case let .failed(reason):
                finish(termination: .failed(reason: reason))
            }
        }
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
            // Reader setup can fail before the delivery lane is created. Keep
            // that rare launch error visible without reintroducing per-event
            // unordered callback tasks on the normal path.
            Task { @MainActor in
                delegate?.controlModeSession(didTerminate: termination)
            }
        }
    }

    /// The protocol queue is the single producer for the delivery lane. A
    /// full lane is a transport failure, because silently dropping a snapshot
    /// or output frame would make the local emulator diverge from tmux.
    private func enqueueDelegateEvent(_ event: TerminalSessionSourceEventDelivery.Event) {
        guard !finished else { return }
        guard let eventDelivery else { return }
        guard eventDelivery.enqueue(event) else {
            handleTransportFailure("tmux delegate delivery exceeded its bounded buffer")
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
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func writeToGateway(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        guard let inputWriter, inputWriter.enqueue(Data(bytes)) else {
            // A failed enqueue means the control client can no longer receive
            // a command. Continuing would leave the core waiting for a fence
            // that cannot arrive and would make the pane appear live forever.
            handleTransportFailure("tmux control input writer is unavailable")
            return
        }
    }

    /// Delivers one event on the protocol executor and suspends the producer
    /// until that event is complete. The continuation gives the output reader
    /// real backpressure without using `queue.sync` as a mutable-state lock.
    private func enqueueOnProtocolQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                operation()
            }
        }
    }

    // MARK: tmux discovery and remote command safety

    /// Resolve an absolute `tmux` path from common locations and `PATH`.
    /// Returns nil when tmux is not installed. Pass `pathEnvironment` to search
    /// a specific `PATH`; nil falls back to the current process environment.
    public static func resolveTmuxExecutable(pathEnvironment: String? = nil) -> String? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        let searchPath = pathEnvironment ?? ProcessInfo.processInfo.environment["PATH"]
        if let searchPath {
            for dir in searchPath.split(separator: ":") {
                candidates.append("\(dir)/tmux")
            }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// OpenSSH joins the command arguments after the destination and passes
    /// them through the remote login shell. Quote each tmux argument before
    /// composing that command, so a session name cannot become shell syntax.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Arguments for the local pty-backed control client. `script(1)` is a
    /// platform primitive for allocating a controlling pty, not a terminal
    /// emulator or a shell-owned attach path. Pass the command as argv instead
    /// of through a login shell, so user startup files cannot write bytes into
    /// the control stream and no shell quoting layer can alter a session name.
    public static func localControlModeArguments(
        tmuxExecutablePath: String,
        target: TmuxAttachTarget
    ) -> [String] {
        [
            // `-F` is script(1)'s immediate-flush flag. `-` is the transcript
            // path for stdout. A filename such as `/dev/null` would make
            // script discard the entire control stream, because macOS script
            // does not treat `-F` as an option that consumes a path. Control
            // output must remain on this pipe so the parser can see it.
            "-q", "-F", "-", "/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE",
            "TERM=xterm-256color",
            tmuxExecutablePath, "-u", "-CC",
        ] + target.tmuxArguments
    }
}

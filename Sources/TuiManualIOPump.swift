import CmuxTerminal
import CmuxTmuxControlMode
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Pure decision logic for the manual-IO tui pump: relay exit
/// classification, reconnect pacing, stdin line encoding, and the per-pane
/// overlay presentation. Everything here is deterministic and unit-testable;
/// process and pipe I/O live in `TuiManualIOPump`.
enum TuiManualIOPumpPolicy {
    /// How one relay process ended, from its exit status and the final JSON
    /// line it printed to stderr (`{"exit":{"reason":...}}`).
    enum RelayExit: Equatable {
        /// The daemon terminal ended; respawning is wrong.
        case terminalEnded
        /// The daemon connection was lost; respawning reattaches and
        /// resyncs from a fresh replay.
        case daemonLost
        /// The pump closed the relay's stdin itself (teardown/respawn).
        case parentClosed
        /// Anything else (spawn failure, protocol error, unknown status).
        case failure
    }

    static func relayExit(status: Int32, stderrText: String?) -> RelayExit {
        let reason = stderrText?
            .split(separator: "\n")
            .reversed()
            .compactMap { line -> String? in
                guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let exit = object["exit"] as? [String: Any]
                else { return nil }
                return exit["reason"] as? String
            }
            .first
        switch (status, reason) {
        case (0, "terminal-ended"): return .terminalEnded
        case (0, "parent-closed"): return .parentClosed
        // Exit 2 is daemon-lost ONLY with the relay's own reason line: a
        // binary without --pipe-io support also exits 2 (usage error), and
        // that must not read as an endlessly-retryable daemon outage.
        case (2, "daemon-lost"): return .daemonLost
        // A compliant pipe relay always emits an explicit reason. Treat a bare
        // zero as a protocol failure, not as a terminal exit. Assuming that
        // every status-0 process ended the terminal hides bad binaries and was
        // the direct cause of the misleading "Terminal session ended" state.
        case (0, _): return .failure
        default: return .failure
        }
    }

    enum NextAction: Equatable {
        case end
        case retry
        case ignore
    }

    static func nextAction(after exit: RelayExit) -> NextAction {
        switch exit {
        case .terminalEnded: return .end
        case .daemonLost, .failure: return .retry
        // The pump closed stdin itself; its own state machine already
        // decided what comes next.
        case .parentClosed: return .ignore
        }
    }

    /// Unexplained relay failures (no exit-reason line: bad binary, usage
    /// error, crash) stop retrying after this many consecutive attempts
    /// without a live interlude; explained daemon-lost exits retry forever.
    static let maxConsecutiveUnexplainedFailures = 5

    /// Reconnect backoff: fast first retries absorb a daemon restart or
    /// handoff, the 30s cap keeps a long outage cheap while the pane shows
    /// its last state. Attempts are 1-based.
    static func retryDelay(attempt: Int) -> Duration {
        let schedule: [Duration] = [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
        ]
        guard attempt >= 1 else { return schedule[0] }
        guard attempt <= schedule.count else { return .seconds(30) }
        return schedule[attempt - 1]
    }

    /// One stdin line forwarding raw input bytes to the relay.
    static func inputLine(bytes: Data) -> Data {
        var line = Data(#"{"input":""#.utf8)
        line.append(Data(bytes.base64EncodedString().utf8))
        line.append(Data(#""}"#.utf8))
        line.append(0x0A)
        return line
    }

    /// Splits a paste into bounded JSON records while preserving byte order.
    /// The relay protocol has no continuation field, so each record is a
    /// complete input command and the FIFO writer is the ordering boundary.
    static func inputLines(bytes: Data, maximumBytesPerRecord: Int = 64 * 1024) -> [Data] {
        guard !bytes.isEmpty else { return [] }
        let chunkSize = max(1, maximumBytesPerRecord)
        return stride(from: 0, to: bytes.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, bytes.count)
            return inputLine(bytes: Data(bytes[start..<end]))
        }
    }

    /// One stdin line driving the daemon-side viewer size.
    static func resizeLine(cols: Int, rows: Int) -> Data {
        Data(#"{"resize":{"cols":\#(max(1, cols)),"rows":\#(max(1, rows))}}"#.utf8 + [0x0A])
    }

    /// What the relay connects to. The bridge's own daemon is addressed by
    /// session name; Harbor addresses foreign local daemons by socket path
    /// and remote daemons by session name over ssh stdio (the pipe-io
    /// protocol is plain stdio, so ssh transports it unchanged).
    enum RelayTarget: Equatable, Sendable {
        case session(String)
        case socket(String)
        case sshSession(destination: String, sessionName: String)
    }

    /// The executable the relay process runs for `target`.
    static func relayExecutablePath(binaryPath: String, target: RelayTarget) -> String {
        switch target {
        case .session, .socket:
            return binaryPath
        case .sshSession:
            return "/usr/bin/ssh"
        }
    }

    /// Relay argv (no shell for local targets; the ssh remote command is one
    /// argument the remote login shell parses, so its fields are quoted).
    static func relayArguments(
        target: RelayTarget,
        terminalID: String,
        cols: Int,
        rows: Int
    ) -> [String] {
        let cols = String(max(1, cols))
        let rows = String(max(1, rows))
        switch target {
        case .session(let sessionName):
            return [
                "attach",
                "--session", sessionName,
                "--terminal", terminalID,
                "--pipe-io",
                "--cols", cols,
                "--rows", rows,
            ]
        case .socket(let socketPath):
            return [
                "attach",
                "--socket", socketPath,
                "--terminal", terminalID,
                "--pipe-io",
                "--cols", cols,
                "--rows", rows,
            ]
        case .sshSession(let destination, let sessionName):
            let remote = [
                "cmux-tui", "attach",
                "--session", shellQuote(sessionName),
                "--terminal", shellQuote(terminalID),
                "--pipe-io",
                "--cols", cols,
                "--rows", rows,
            ].joined(separator: " ")
            // BatchMode: a relay respawn loop must fail fast, never wedge on
            // an interactive auth prompt it has no TTY to show.
            // The relay carries JSONL on stdin/stdout. Make the no-pty
            // contract explicit so a user's SSH config cannot add terminal
            // line discipline to the protocol.
            return ["-T", "-o", "EscapeChar=none", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", destination, remote]
        }
    }

    /// Back-compat argv builder for the bridge's own daemon session.
    static func relayArguments(
        sessionName: String,
        terminalID: String,
        cols: Int,
        rows: Int
    ) -> [String] {
        relayArguments(target: .session(sessionName), terminalID: terminalID, cols: cols, rows: rows)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Overlay presentation for one pump state, in the same visual family
    /// as the cloud terminal reconnect overlay.
    static func overlayPresentation(
        state: TuiManualIOPump.State
    ) -> CloudTerminalReconnectOverlayPolicy.Presentation? {
        switch state {
        case .connecting, .live:
            return nil
        case .reconnecting(let attempt):
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(
                    localized: "tui.overlay.reconnecting.title",
                    defaultValue: "Reconnecting to the terminal session"
                ),
                detail: String(
                    localized: "tui.overlay.reconnecting.detail",
                    defaultValue: "The session daemon is unreachable (attempt \(attempt)). The terminal shows its last state; input is paused."
                ),
                showsProgress: true,
                showsReconnectButton: true
            )
        case .ended:
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(
                    localized: "tui.overlay.ended.title",
                    defaultValue: "Terminal session ended"
                ),
                detail: String(
                    localized: "tui.overlay.ended.detail",
                    defaultValue: "The daemon-backed terminal has ended. Close the tab, or keep it to read the final screen."
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        case .failed:
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(
                    localized: "tui.overlay.failed.title",
                    defaultValue: "Terminal backend unavailable"
                ),
                detail: String(
                    localized: "tui.overlay.failed.detail",
                    defaultValue: "The relay for this daemon-backed terminal keeps failing. Check the cmux-tui binary path in Settings, then retry."
                ),
                showsProgress: false,
                showsReconnectButton: true
            )
        }
    }
}

/// Cross-thread input channel between the Ghostty IO thread (which delivers
/// the surface's encoded input bytes) and the pump's relay stdin writer.
/// Lock-guarded because `manualInputHandler` must not touch the main actor.
final class TuiManualIOInputChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: ControlModeProcessInputWriter?
    private var failureHandler: (@Sendable (String, Int) -> Void)?

    func setFailureHandler(_ handler: @escaping @Sendable (String, Int) -> Void) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    /// Swaps the live relay stdin. `nil` pauses input (dropped, never
    /// queued: replaying stale input into a shell after a reconnect is
    /// worse than losing keystrokes typed into a dead pane).
    func setHandle(_ newHandle: FileHandle?, generation: Int) {
        let replacement = newHandle.map { handle in
            let writer = ControlModeProcessInputWriter(
                label: "cmux.tuiManualIO.stdin.\(UUID().uuidString)",
                maxPendingBytes: 8 * 1024 * 1024,
                onFailure: { [weak self] reason in
                    self?.lock.lock()
                    let handler = self?.failureHandler
                    self?.lock.unlock()
                    handler?(reason, generation)
                }
            )
            writer.attach(to: handle)
            return writer
        }
        lock.lock()
        let previous = writer
        writer = replacement
        lock.unlock()
        previous?.close()
    }

    func send(_ line: Data) {
        lock.lock()
        let target = writer
        lock.unlock()
        target?.enqueue(line)
    }

    /// Closes and detaches the current handle (relay stdin EOF = clean
    /// detach on the relay side).
    func closeHandle() {
        lock.lock()
        let target = writer
        writer = nil
        lock.unlock()
        target?.close()
    }
}

/// Owns the `cmux-tui attach --terminal <id> --pipe-io` relay for one
/// manual-mirror terminal panel: pumps relay stdout into the Ghostty
/// surface, forwards the surface's encoded input to relay stdin, drives
/// daemon-side sizing from applied surface resizes, and runs the reconnect
/// state machine when the relay dies.
///
/// Data-path invariant: the surface parses the same byte stream the daemon
/// terminal emitted, so the surface's input encodings always match the
/// daemon terminal's mode state. The mode-mirroring/re-encoding bug class
/// of the exec attach bridge cannot exist on this path.
@MainActor
final class TuiManualIOPump {
    /// A pump is either waiting for its owner to commit a durable terminal
    /// lease or bound to exactly one lease. Modeling this as a phase prevents
    /// an empty string from becoming an accidental terminal identity.
    enum Binding: Equatable {
        case pending
        case bound(terminalID: String)
    }

    enum State: Equatable {
        /// First attach in flight; the pane is empty, no overlay.
        case connecting
        /// Relay bytes are flowing.
        case live
        /// The relay died recoverably; a respawn is scheduled (1-based
        /// attempt count shown in the overlay).
        case reconnecting(attempt: Int)
        /// The daemon terminal ended; the pane keeps its final frame.
        case ended
        /// The relay failed repeatedly with no explanation (bad binary,
        /// crash loop); automatic retries stopped, manual retry offered.
        case failed
    }

    private(set) var state: State = .connecting {
        didSet {
            guard oldValue != state else { return }
            log("state \(oldValue) -> \(state)")
            onStateChange?()
        }
    }

    /// Posted on every state change (wired to the workspace's overlay
    /// resynchronization).
    var onStateChange: (() -> Void)?

    /// The immutable identity phase for this pump. A pending surface never
    /// starts a relay or claims an arbitrary terminal.
    private(set) var binding: Binding
    var isActivated: Bool {
        if case .bound = binding { return true }
        return false
    }
    /// Compatibility accessor for diagnostics and close bookkeeping. It is
    /// optional because pending is a real lifecycle state, not an empty id.
    var terminalID: String? {
        guard case let .bound(terminalID) = binding else { return nil }
        return terminalID
    }
    private let binaryPath: String
    private let target: TuiManualIOPumpPolicy.RelayTarget
    private let environment: [String: String]
    private let inputChannel = TuiManualIOInputChannel()
    /// Injected so tests can run the backoff deterministically. Production
    /// is a cancellation-checking `Task.sleep`.
    private let sleep: @Sendable (Duration) async throws -> Void

    private weak var surface: TerminalSurface?
    /// When the pump is used as a foreign-session source, the bytes go to a
    /// neutral session delegate instead of directly into a local surface.
    /// Keeping this mode in the same pump preserves one relay/reconnect
    /// implementation for app-owned and Harbor-owned cmux-tui terminals.
    private weak var sourceDelegate: (any TerminalSessionSourceDelegate)?
    private var sourceMode = false
    private var sourceNeedsResync = false
    private var didNotifySourceEnd = false
    private var process: Process?
    private var stdoutReader: RemoteTmuxProcessOutputReader?
    private var stdoutTask: Task<Void, Never>?
    private var stderrReader: RemoteTmuxProcessOutputReader?
    private var stderrTask: Task<Void, Never>?
    private var stderrBox = TuiManualIOStderrBox()
    private var retryTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    /// Process termination and stderr EOF race (termination is not EOF);
    /// classification needs the relay's final stderr line and stdout replay,
    /// so it runs only once all three have arrived for the current generation.
    private var pendingExitStatus: Int32?
    private var stdoutDrainedGeneration = 0
    private var stderrDrainedGeneration = 0
    /// Fences callbacks from an old relay after a respawn or stop.
    private var generation = 0
    private var stopped = false
    private var everRenderedAttach = false
    private var consecutiveUnexplainedFailures = 0
    private var lastKnownGrid: (cols: Int, rows: Int)?
    private var lastSentGrid: (cols: Int, rows: Int)?
    /// A surface can report several applied cell grids during one AppKit
    /// resize. The daemon relay has no reply block that can gate these writes,
    /// so app-owned pumps use a trailing coalescer. Harbor source adapters
    /// already coalesce at their session controller and bypass this delay.
    private static let resizeDebounce = Duration.milliseconds(180)

    /// Called when Retry is pressed before provisioning has produced an id.
    /// The owner supplies the provisioning transaction.
    var onActivationRetry: (() -> Void)?

    convenience init(
        binaryPath: String,
        sessionName: String,
        terminalID: String? = nil,
        environment: [String: String],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(
            binaryPath: binaryPath,
            target: .session(sessionName),
            terminalID: terminalID,
            environment: environment,
            sleep: sleep
        )
    }

    /// Harbor: relay to a foreign daemon (local socket or ssh session).
    init(
        binaryPath: String,
        target: TuiManualIOPumpPolicy.RelayTarget,
        terminalID: String? = nil,
        environment: [String: String],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.binaryPath = binaryPath
        self.target = target
        if let terminalID {
            let normalized = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.binding = normalized.isEmpty ? .pending : .bound(terminalID: normalized)
        } else {
            self.binding = .pending
        }
        self.environment = environment
        self.sleep = sleep
        inputChannel.setFailureHandler { [weak self] reason, generation in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleInputTransportFailure(reason, generation: generation)
            }
        }
    }

    /// Completes an asynchronous provisioning transaction. The identity is
    /// write-once for a pump, which prevents a late result from retargeting a
    /// live relay to another daemon terminal.
    func activate(terminalID: String) {
        let normalized = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stopped, !normalized.isEmpty else { return }
        switch binding {
        case .pending:
            binding = .bound(terminalID: normalized)
        case let .bound(existing) where existing != normalized:
            log("ignoring terminal identity replacement old=\(existing.prefix(12)) new=\(normalized.prefix(12))")
            return
        case .bound:
            break
        }
        consecutiveUnexplainedFailures = 0
        if state == .failed { state = .connecting }
        if sourceMode || surface != nil {
            spawnRelay()
        }
    }

    /// Fails a pending transaction without claiming that the daemon terminal
    /// ended. Retry remains explicit and can start a new provisioning request.
    func failActivation(reason: String) {
        guard !stopped, case .pending = binding else { return }
        retryTask?.cancel()
        retryTask = nil
        state = .failed
        notifySourceTermination(.failed(reason: reason))
    }

    /// The surface's `manualInputHandler`: runs on Ghostty's IO thread, so
    /// it only touches the lock-guarded input channel.
    nonisolated func makeManualInputHandler() -> @Sendable (TerminalManualInput) -> Void {
        let channel = inputChannel
        return { input in
            switch input {
            case .bytes(let bytes):
                for line in TuiManualIOPumpPolicy.inputLines(bytes: bytes) {
                    channel.send(line)
                }
            case .namedKey:
                // No key-name resolver is installed on this surface, so
                // Ghostty encodes every key itself; a named key here is a
                // wiring bug, and dropping it is safer than guessing bytes.
                break
            }
        }
    }

    /// Binds the pump to its surface and starts the relay at the first
    /// known grid size. Applied resizes are the steady-state signal, but a
    /// session-restored panel can mount at exactly the runtime's initial
    /// grid (no apply ever fires), so the pump also samples the grid
    /// directly when the runtime is (or becomes) ready and attaches
    /// eagerly; a later mount just resizes the daemon terminal.
    func start(surface: TerminalSurface) {
        guard !sourceMode else { return }
        self.surface = surface
        surface.onManualSizeApplied = { [weak self] sample in
            self?.handleSizingSample(cols: sample.columns, rows: sample.rows)
        }
        surface.onRuntimeReady = { [weak self, weak surface] in
            guard let self, let surface else { return }
            surface.flushPendingManualSizeReportIfAttached()
            self.sampleCurrentGrid(of: surface)
        }
        surface.flushPendingManualSizeReportIfAttached()
        sampleCurrentGrid(of: surface)
    }

    /// Starts the same pipe-IO relay without creating or owning a daemon
    /// terminal. Harbor uses this for a terminal that belongs to a foreign
    /// cmux-tui daemon.
    func start(
        initialSize: TerminalSize,
        delegate: any TerminalSessionSourceDelegate
    ) {
        guard !stopped, !sourceMode else { return }
        sourceMode = true
        sourceDelegate = delegate
        lastKnownGrid = (max(1, initialSize.columns), max(1, initialSize.rows))
        // The daemon terminal owns the rendered grid. Ghostty must not locally
        // reflow it while a replay or resize frame is in flight.
        delegate.controlModeSession(didChangeResizePolicy: .preserveScreen)
        if case .bound = binding {
            spawnRelay()
        }
    }

    /// Sends already-encoded bytes to the relay. This is the source-facing
    /// counterpart of `makeManualInputHandler`.
    nonisolated func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for line in TuiManualIOPumpPolicy.inputLines(bytes: Data(bytes)) {
            inputChannel.send(line)
        }
    }

    /// Drives the foreign daemon's viewer size from the local applied grid.
    func resize(_ size: TerminalSize) {
        guard !stopped else { return }
        handleSizingSample(cols: size.columns, rows: size.rows)
    }

    private func sampleCurrentGrid(of surface: TerminalSurface) {
        guard let sample = surface.rawSizingSample(),
              sample.columns > 1, sample.rows > 1 else { return }
        handleSizingSample(cols: sample.columns, rows: sample.rows)
    }

    /// The overlay's Reconnect button: skip the remaining backoff, or leave
    /// the failed state for another round of attempts.
    func retryNow() {
        if case .pending = binding {
            guard !stopped else { return }
            onActivationRetry?()
            return
        }
        switch state {
        case .reconnecting, .failed:
            guard !stopped else { return }
            consecutiveUnexplainedFailures = 0
            retryTask?.cancel()
            retryTask = nil
            state = .reconnecting(attempt: 1)
            spawnRelay()
        case .connecting, .live, .ended:
            break
        }
    }

    /// Tears the pump down (panel closed, app quitting, transfer discard).
    /// The relay sees stdin EOF and detaches cleanly; the daemon terminal
    /// itself is closed (or kept) by the bridge's existing close semantics.
    func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stdoutReader?.close()
        stdoutReader = nil
        stderrTask?.cancel()
        stderrTask = nil
        stderrReader?.close()
        stderrReader = nil
        inputChannel.closeHandle()
        generation += 1
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        sourceDelegate = nil
    }

    var overlayPresentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        TuiManualIOPumpPolicy.overlayPresentation(state: state)
    }

    // MARK: - Sizing

    private func handleSizingSample(cols: Int, rows: Int) {
        guard !stopped else { return }
        let grid = (max(1, cols), max(1, rows))
        lastKnownGrid = grid
        guard case .bound = binding else { return }
        if process == nil, retryTask == nil, case .connecting = state {
            spawnRelay()
            return
        }
        if let sent = lastSentGrid, sent == grid {
            resizeTask?.cancel()
            resizeTask = nil
            return
        }

        if sourceMode {
            // HarborManualSessionController owns the trailing coalescer for
            // foreign sources. Sending here immediately keeps the source
            // controller's one debounce window from becoming two.
            resizeTask?.cancel()
            resizeTask = nil
            lastSentGrid = grid
            inputChannel.send(TuiManualIOPumpPolicy.resizeLine(cols: grid.0, rows: grid.1))
            return
        }

        let generation = self.generation
        resizeTask?.cancel()
        let sleep = sleep
        resizeTask = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.resizeDebounce)
            } catch {
                return
            }
            guard let self, !self.stopped, !Task.isCancelled,
                  self.generation == generation,
                  let latest = self.lastKnownGrid,
                  self.process != nil else { return }
            guard self.lastSentGrid?.cols != latest.cols ||
                    self.lastSentGrid?.rows != latest.rows else { return }
            self.resizeTask = nil
            self.lastSentGrid = latest
            self.inputChannel.send(
                TuiManualIOPumpPolicy.resizeLine(cols: latest.0, rows: latest.1)
            )
        }
    }

    // MARK: - Relay lifecycle

    private func spawnRelay() {
        guard !stopped, case let .bound(terminalID) = binding else { return }
        // Terminal states only leave through retryNow (which transitions
        // back to reconnecting first) or teardown; a straggler retry task
        // or sizing sample must not resurrect the relay.
        if state == .ended || state == .failed { return }
        let executablePath = TuiManualIOPumpPolicy.relayExecutablePath(binaryPath: binaryPath, target: target)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        generation += 1
        let spawnGeneration = generation
        let grid = lastKnownGrid ?? (80, 24)
        lastSentGrid = grid

        // The pipe-IO relay owns replay framing. It prefixes every replay after
        // the first with ESC c + erase-scrollback, so the renderer must not
        // inject a second reset or erase the beginning of the replay.
        sourceNeedsResync = sourceMode && everRenderedAttach
        resizeTask?.cancel()
        resizeTask = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = TuiManualIOPumpPolicy.relayArguments(
            target: target,
            terminalID: terminalID,
            cols: grid.cols,
            rows: grid.rows
        )
        // The relay environment is an override set. Replacing the inherited
        // environment can remove HOME/PATH/locale and make a valid client
        // fail only when launched from the GUI rather than a shell.
        process.environment = ProcessInfo.processInfo.environment.merging(environment) {
            _, override in override
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrBox = TuiManualIOStderrBox()
        self.stderrBox = stderrBox
        pendingExitStatus = nil
        stdoutDrainedGeneration = 0
        stderrDrainedGeneration = 0
        guard let reader = RemoteTmuxProcessOutputReader(
            readingFrom: stdoutPipe.fileHandleForReading,
            label: "cmux.tuiManualIO.stdout",
            maxPendingChunks: 512,
            maxPendingBytes: 8 * 1024 * 1024,
            onOverflow: { [weak self] in
                // The surface stopped consuming; treat like a dead relay so
                // a respawn resyncs from a bounded replay.
                self?.handleRelayExit(generation: spawnGeneration, forcedExit: .daemonLost)
            }
        ) else {
            log("stdout reader setup failed")
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        guard let diagnosticReader = RemoteTmuxProcessOutputReader(
            readingFrom: stderrPipe.fileHandleForReading,
            label: "cmux.tuiManualIO.stderr",
            maxPendingChunks: 256,
            maxPendingBytes: 1024 * 1024,
            onOverflow: { [weak self] in
                // Diagnostics are bounded too. Losing the final exit record
                // means the relay result is no longer trustworthy, so retry
                // through the same transport-recovery path as stdout loss.
                self?.handleRelayExit(generation: spawnGeneration, forcedExit: .daemonLost)
            }
        ) else {
            reader.close()
            log("stderr reader setup failed")
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        stdoutReader?.close()
        stdoutReader = reader
        stderrReader?.close()
        stderrReader = diagnosticReader
        stdoutTask?.cancel()
        stdoutTask = Task { @MainActor [weak self] in
            for await chunk in reader.stream {
                guard let self, self.generation == spawnGeneration, !self.stopped else { break }
                reader.release(chunk)
                if let sourceDelegate = self.sourceDelegate {
                    let resyncing = self.sourceNeedsResync
                    let bytes = Array(chunk)
                    if resyncing { self.sourceNeedsResync = false }
                    let isSnapshot = !self.everRenderedAttach || resyncing
                    if isSnapshot {
                        sourceDelegate.controlModeSession(didProduceSnapshot: bytes)
                    } else {
                        sourceDelegate.controlModeSession(didProduceOutput: bytes)
                    }
                } else {
                    self.surface?.processRemoteOutput(chunk)
                }
                self.everRenderedAttach = true
                self.consecutiveUnexplainedFailures = 0
                if self.state != .live {
                    self.state = .live
                }
            }
            self?.handleStdoutDrained(generation: spawnGeneration)
        }
        stderrTask?.cancel()
        stderrTask = Task { @MainActor [weak self] in
            for await chunk in diagnosticReader.stream {
                guard let self, self.generation == spawnGeneration, !self.stopped else {
                    diagnosticReader.release(chunk)
                    break
                }
                stderrBox.append(chunk)
                diagnosticReader.release(chunk)
            }
            self?.handleStderrDrained(generation: spawnGeneration)
        }

        process.terminationHandler = { [weak self] finished in
            // Process termination is not pipe EOF. Ask the shared reader to
            // drain bytes that the relay wrote immediately before exit, then
            // let the stream finish. This preserves the final replay frame.
            reader.processDidExit()
            diagnosticReader.processDidExit()
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleRelayTermination(generation: spawnGeneration, status: status)
            }
        }

        // Publish the process and install both write/read endpoints before
        // launching it. A relay can fail synchronously (for example, a stale
        // terminal id); assigning these after `run()` lets its termination
        // callback finish a reader that has not been attached yet and loses
        // the final protocol bytes.
        self.process = process
        inputChannel.setHandle(stdinPipe.fileHandleForWriting, generation: spawnGeneration)
        do {
            try process.run()
        } catch {
            log("spawn failed: \(error)")
            process.terminationHandler = nil
            self.process = nil
            inputChannel.closeHandle()
            reader.close()
            diagnosticReader.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        // The child owns its inherited stdin endpoint and the input channel
        // owns a duplicate. Closing this parent reference makes relay EOF
        // deterministic when the channel is stopped.
        try? stdinPipe.fileHandleForWriting.close()
        // `Process` retains the pipe objects, but the parent must not retain
        // their write ends. The readers use EOF, rather than process
        // termination, as the protocol boundary. Leaving either write end
        // open makes a clean relay exit wait forever for a writer that is
        // still owned by this object.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        // Both readers own duplicates. Closing the parent's read endpoints
        // prevents an accidental local reference from delaying EOF.
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        log("relay spawned generation=\(spawnGeneration) grid=\(grid.cols)x\(grid.rows)")
    }

    private func handleStderrDrained(generation drainedGeneration: Int) {
        guard drainedGeneration == generation, !stopped else { return }
        stderrDrainedGeneration = drainedGeneration
        finishRelayIfDrained(generation: drainedGeneration)
    }

    private func handleStdoutDrained(generation drainedGeneration: Int) {
        guard drainedGeneration == generation, !stopped else { return }
        stdoutDrainedGeneration = drainedGeneration
        finishRelayIfDrained(generation: drainedGeneration)
    }

    private func handleRelayTermination(generation exitedGeneration: Int, status: Int32) {
        guard exitedGeneration == generation, !stopped else { return }
        pendingExitStatus = status
        finishRelayIfDrained(generation: exitedGeneration)
    }

    private func finishRelayIfDrained(generation: Int) {
        guard generation == self.generation,
              stdoutDrainedGeneration == generation,
              stderrDrainedGeneration == generation,
              let status = pendingExitStatus else { return }
        pendingExitStatus = nil
        handleRelayExit(generation: generation, status: status)
    }

    private func handleRelayExit(
        generation exitedGeneration: Int,
        status: Int32? = nil,
        forcedExit: TuiManualIOPumpPolicy.RelayExit? = nil
    ) {
        guard exitedGeneration == generation, !stopped else { return }
        // The reader can report EOF or overflow before Process delivers its
        // termination callback. End the child explicitly before dropping the
        // last strong reference, otherwise a failed relay can remain orphaned
        // while the retry state starts a second one.
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        inputChannel.closeHandle()
        resizeTask?.cancel()
        resizeTask = nil
        stdoutReader?.close()
        stdoutReader = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stderrReader?.close()
        stderrReader = nil
        stderrTask?.cancel()
        stderrTask = nil
        process = nil
        let exit = forcedExit
            ?? TuiManualIOPumpPolicy.relayExit(status: status ?? -1, stderrText: stderrBox.text())
#if DEBUG
        let stderrTail = (stderrBox.text() ?? "").suffix(300).replacingOccurrences(of: "\n", with: " | ")
        let terminalDescription = terminalID ?? "pending"
        log("relay exit \(exit) terminal=\(terminalDescription.prefix(12)) status=\(status.map(String.init) ?? "nil") stderr=\(stderrTail)")
#else
        log("relay exit \(exit)")
#endif
        switch TuiManualIOPumpPolicy.nextAction(after: exit) {
        case .end:
            state = .ended
            notifySourceTermination(.ended(reason: "cmux-tui terminal ended"))
        case .retry:
            if exit == .failure {
                noteUnexplainedFailureThenRetryOrFail()
            } else {
                scheduleRetry()
            }
        case .ignore:
            break
        }
    }

    private func handleInputTransportFailure(_ reason: String, generation failedGeneration: Int) {
        guard !stopped, failedGeneration == generation else { return }
        log("relay input failed generation=\(failedGeneration): \(reason)")
        // A closed or overfull stdin cannot be repaired in place. Recycle the
        // relay so the next attach receives a clean replay and the source's
        // ordering contract remains intact.
        handleRelayExit(generation: failedGeneration, forcedExit: .daemonLost)
    }

    /// Unexplained failures (spawn failure, usage error, crash) stop
    /// retrying after a bounded streak so a permanently broken binary
    /// converges to a visible failed state instead of a silent retry loop.
    private func noteUnexplainedFailureThenRetryOrFail() {
        consecutiveUnexplainedFailures += 1
        if consecutiveUnexplainedFailures
            >= TuiManualIOPumpPolicy.maxConsecutiveUnexplainedFailures {
            retryTask?.cancel()
            retryTask = nil
            state = .failed
            notifySourceTermination(.failed(reason: "cmux-tui relay failed"))
            return
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        let attempt: Int
        if case .reconnecting(let previous) = state {
            attempt = previous + 1
        } else {
            attempt = 1
        }
        state = .reconnecting(attempt: attempt)
        let delay = TuiManualIOPumpPolicy.retryDelay(attempt: attempt)
        let sleep = sleep
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.retryTask = nil
            self.spawnRelay()
        }
    }

    private nonisolated func log(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog("tuiManualIO.\(message())")
#endif
    }

    private func notifySourceTermination(_ termination: TerminalSessionTermination) {
        guard sourceMode, !didNotifySourceEnd else { return }
        didNotifySourceEnd = true
        let delegate = sourceDelegate
        sourceDelegate = nil
        delegate?.controlModeSession(didTerminate: termination)
    }
}

/// Adapts the main-actor cmux-tui pump to the transport-neutral source
/// contract. Source calls can arrive from the Ghostty IO thread, so the
/// adapter uses one bounded FIFO instead of one independent actor task per
/// call. A sequence such as start → resize → stop therefore cannot reorder
/// when the main actor is busy.
final class HarborTuiSessionSourceAdapter: TerminalSessionSource, @unchecked Sendable {
    private enum Operation: Sendable {
        case start(initialSize: TerminalSize, delegate: any TerminalSessionSourceDelegate)
        case input([UInt8])
        case resize(TerminalSize)
        case stop
    }

    private let pump: TuiManualIOPump
    private let name: String
    private let continuation: AsyncStream<Operation>.Continuation
    private let worker: Task<Void, Never>
    private let stateLock = NSLock()
    private var closed = false
    private var overflowReported = false
    private weak var delegate: (any TerminalSessionSourceDelegate)?

    init(pump: TuiManualIOPump, displayName: String) {
        self.pump = pump
        self.name = displayName
        let (stream, continuation) = AsyncStream<Operation>.makeStream(
            bufferingPolicy: .bufferingOldest(2048)
        )
        self.continuation = continuation
        self.worker = Task { @MainActor [pump] in
            for await operation in stream {
                switch operation {
                case let .start(initialSize, delegate):
                    pump.start(initialSize: initialSize, delegate: delegate)
                case let .input(bytes):
                    pump.sendInput(bytes)
                case let .resize(size):
                    pump.resize(size)
                case .stop:
                    pump.stop()
                    return
                }
            }
        }
    }

    deinit {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        continuation.finish()
        worker.cancel()
    }

    var displayName: String { name }

    func start(initialSize: TerminalSize, delegate: any TerminalSessionSourceDelegate) {
        stateLock.lock()
        self.delegate = delegate
        stateLock.unlock()
        enqueue(.start(initialSize: initialSize, delegate: delegate))
    }

    func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        enqueue(.input(bytes))
    }

    func resize(_ size: TerminalSize) {
        enqueue(.resize(size))
    }

    func stop() {
        enqueue(.stop)
    }

    private func enqueue(_ operation: Operation) {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        let result = continuation.yield(operation)
        var shouldReport = false
        if case .dropped = result, !overflowReported {
            overflowReported = true
            closed = true
            shouldReport = true
        }
        let delegate = self.delegate
        stateLock.unlock()

        guard shouldReport else { return }
        continuation.finish()
        // Dropping a source operation would make the local viewer diverge
        // from its daemon. Stop the pump and report a typed transport failure
        // instead of silently losing input or a resize.
        Task { @MainActor [pump, delegate] in
            pump.stop()
            delegate?.controlModeSession(
                didTerminate: .failed(reason: "cmux-tui source operation queue exceeded its bounded capacity")
            )
        }
    }
}

/// Process-wide pump registry keyed by surface id. The surface id is stable
/// across detach transfers between workspaces, so a global registry needs
/// no transfer bookkeeping: overlays and close paths look pumps up by the
/// surface they render.
@MainActor
final class TuiManualIOPumpRegistry {
    static let shared = TuiManualIOPumpRegistry()

    private var pumps: [UUID: TuiManualIOPump] = [:]

    func register(_ pump: TuiManualIOPump, surfaceID: UUID) {
        pumps[surfaceID]?.stop()
        pumps[surfaceID] = pump
    }

    func pump(forSurfaceID surfaceID: UUID) -> TuiManualIOPump? {
        pumps[surfaceID]
    }

    /// Stops and forgets the pump when its panel is discarded for real (not
    /// a detach transfer). The relay sees stdin EOF and detaches cleanly.
    func stopAndRemove(surfaceID: UUID) {
        pumps.removeValue(forKey: surfaceID)?.stop()
    }
}

/// Lock-guarded stderr accumulator: the relay prints its machine-readable
/// exit reason as the final stderr line.
final class TuiManualIOStderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ new: Data) {
        lock.lock()
        // Only the tail matters (final JSON line); bound the buffer.
        data.append(new)
        if data.count > 64 * 1024 {
            data.removeFirst(data.count - 64 * 1024)
        }
        lock.unlock()
    }

    func text() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}

import CmuxTerminal
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// Where a `--pipe-io` relay finds its daemon: a named local session
/// (`attach --session <name>`) or an explicit control socket
/// (`--socket <path> attach`), e.g. the local mux socket a cloud machine's
/// headless link exposes.
enum TuiManualIORelayTarget: Equatable {
    case session(String)
    case socket(String)
}

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
        case (0, _): return .terminalEnded
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

    /// One stdin line driving the daemon-side viewer size.
    static func resizeLine(cols: Int, rows: Int) -> Data {
        Data(#"{"resize":{"cols":\#(max(1, cols)),"rows":\#(max(1, rows))}}"#.utf8 + [0x0A])
    }

    /// Relay argv (no shell, no quoting: the pump spawns the binary
    /// directly, so the exec-wrapper and env(1) classes of the exec attach
    /// pane cannot exist here). `--socket` is a global option and precedes
    /// the subcommand, matching `CloudTuiCommandLine`.
    static func relayArguments(
        target: TuiManualIORelayTarget,
        terminalID: String,
        cols: Int,
        rows: Int
    ) -> [String] {
        let scoped: [String]
        switch target {
        case .session(let name):
            scoped = ["attach", "--session", name]
        case .socket(let path):
            scoped = ["--socket", path, "attach"]
        }
        return scoped + [
            "--terminal", terminalID,
            "--pipe-io",
            "--cols", String(max(1, cols)),
            "--rows", String(max(1, rows)),
        ]
    }

    /// Emitted into the surface before a respawned relay's replay: the
    /// replay REPLACES terminal state, and only the pump knows whether this
    /// surface already rendered a previous attach.
    static let resyncReset = Data([0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A]) // ESC c, CSI 3 J

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
                    defaultValue: "Terminal relay unavailable"
                ),
                detail: String(
                    localized: "tui.overlay.failed.detail",
                    defaultValue: "The relay for this terminal keeps failing. Retry now, or close the pane and reopen the terminal from the machine\u{2019}s tree."
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
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "cmux.tuiManualIO.stdin", qos: .userInitiated)

    /// Swaps the live relay stdin. `nil` pauses input (dropped, never
    /// queued: replaying stale input into a shell after a reconnect is
    /// worse than losing keystrokes typed into a dead pane).
    func setHandle(_ newHandle: FileHandle?) {
        lock.lock()
        handle = newHandle
        lock.unlock()
    }

    func send(_ line: Data) {
        lock.lock()
        let target = handle
        lock.unlock()
        guard let target else { return }
        queue.async {
            // A failed write means the relay just died; the pump's
            // termination handler owns that transition.
            try? target.write(contentsOf: line)
        }
    }

    /// Closes and detaches the current handle (relay stdin EOF = clean
    /// detach on the relay side).
    func closeHandle() {
        lock.lock()
        let target = handle
        handle = nil
        lock.unlock()
        guard let target else { return }
        queue.async {
            try? target.close()
        }
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
/// of the exec attach pane cannot exist on this path.
@MainActor
final class TuiManualIOPump {
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

    let terminalID: String
    private let binaryPath: String
    private let target: TuiManualIORelayTarget
    private let environment: [String: String]
    private let inputChannel = TuiManualIOInputChannel()
    /// Injected so tests can run the backoff deterministically. Production
    /// is a cancellation-checking `Task.sleep`.
    private let sleep: @Sendable (Duration) async throws -> Void

    private weak var surface: TerminalSurface?
    private var process: Process?
    private var stdoutReader: RemoteTmuxProcessOutputReader?
    private var stdoutTask: Task<Void, Never>?
    private var stderrBox = TuiManualIOStderrBox()
    private var retryTask: Task<Void, Never>?
    /// Process termination and stderr EOF race (termination is not EOF);
    /// classification needs the relay's final stderr line, so it runs only
    /// once BOTH have arrived for the current generation.
    private var pendingExitStatus: Int32?
    private var stderrDrainedGeneration = 0
    /// Fences callbacks from an old relay after a respawn or stop.
    private var generation = 0
    private var stopped = false
    private var everRenderedAttach = false
    private var consecutiveUnexplainedFailures = 0
    private var lastKnownGrid: (cols: Int, rows: Int)?
    private var lastSentGrid: (cols: Int, rows: Int)?

    init(
        binaryPath: String,
        target: TuiManualIORelayTarget,
        terminalID: String,
        environment: [String: String],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.binaryPath = binaryPath
        self.target = target
        self.terminalID = terminalID
        self.environment = environment
        self.sleep = sleep
    }

    /// The surface's `manualInputHandler`: runs on Ghostty's IO thread, so
    /// it only touches the lock-guarded input channel.
    nonisolated func makeManualInputHandler() -> @Sendable (TerminalManualInput) -> Void {
        let channel = inputChannel
        return { input in
            switch input {
            case .bytes(let bytes):
                channel.send(TuiManualIOPumpPolicy.inputLine(bytes: bytes))
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

    private func sampleCurrentGrid(of surface: TerminalSurface) {
        guard let sample = surface.rawSizingSample(),
              sample.columns > 1, sample.rows > 1 else { return }
        handleSizingSample(cols: sample.columns, rows: sample.rows)
    }

    /// The overlay's Reconnect button: skip the remaining backoff, or leave
    /// the failed state for another round of attempts.
    func retryNow() {
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
    /// itself stays alive in the machine's session.
    func stop() {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stdoutReader?.close()
        stdoutReader = nil
        inputChannel.closeHandle()
        generation += 1
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    var overlayPresentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        TuiManualIOPumpPolicy.overlayPresentation(state: state)
    }

    // MARK: - Sizing

    private func handleSizingSample(cols: Int, rows: Int) {
        guard !stopped else { return }
        lastKnownGrid = (cols, rows)
        if process == nil, retryTask == nil, case .connecting = state {
            spawnRelay()
            return
        }
        if let sent = lastSentGrid, sent == (cols, rows) { return }
        lastSentGrid = (cols, rows)
        inputChannel.send(TuiManualIOPumpPolicy.resizeLine(cols: cols, rows: rows))
    }

    // MARK: - Relay lifecycle

    private func spawnRelay() {
        guard !stopped, let surface else { return }
        // Terminal states only leave through retryNow (which transitions
        // back to reconnecting first) or teardown; a straggler retry task
        // or sizing sample must not resurrect the relay.
        if state == .ended || state == .failed { return }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        generation += 1
        let spawnGeneration = generation
        let grid = lastKnownGrid ?? (80, 24)
        lastSentGrid = grid

        // A respawned relay replays the daemon terminal from scratch; reset
        // the surface first so the replay replaces the stale frame instead
        // of stacking on it.
        if everRenderedAttach {
            surface.processRemoteOutput(TuiManualIOPumpPolicy.resyncReset)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = TuiManualIOPumpPolicy.relayArguments(
            target: target,
            terminalID: terminalID,
            cols: grid.cols,
            rows: grid.rows
        )
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrBox = TuiManualIOStderrBox()
        self.stderrBox = stderrBox
        pendingExitStatus = nil
        // Blocking drain to EOF on a throwaway queue: it continuously
        // empties the pipe (a full pipe would wedge the relay) and EOF is
        // the only signal that the final exit-reason line has landed.
        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue(label: "cmux.tuiManualIO.stderr", qos: .utility).async { [weak self] in
            stderrBox.append(stderrHandle.readDataToEndOfFile())
            Task { @MainActor [weak self] in
                self?.handleStderrDrained(generation: spawnGeneration)
            }
        }

        let reader = RemoteTmuxProcessOutputReader(
            label: "cmux.tuiManualIO.stdout",
            maxPendingChunks: 512,
            maxPendingBytes: 8 * 1024 * 1024,
            onOverflow: { [weak self] in
                // The surface stopped consuming; treat like a dead relay so
                // a respawn resyncs from a bounded replay.
                self?.handleRelayExit(generation: spawnGeneration, forcedExit: .daemonLost)
            }
        )
        stdoutReader?.close()
        stdoutReader = reader
        stdoutTask?.cancel()
        stdoutTask = Task { @MainActor [weak self] in
            for await chunk in reader.stream {
                guard let self, self.generation == spawnGeneration, !self.stopped else { break }
                reader.release(chunk)
                self.surface?.processRemoteOutput(chunk)
                self.everRenderedAttach = true
                self.consecutiveUnexplainedFailures = 0
                if self.state != .live {
                    self.state = .live
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleRelayTermination(generation: spawnGeneration, status: status)
            }
        }

        do {
            try process.run()
        } catch {
            log("spawn failed: \(error)")
            reader.close()
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        self.process = process
        inputChannel.setHandle(stdinPipe.fileHandleForWriting)
        reader.attach(to: stdoutPipe.fileHandleForReading)
        log("relay spawned generation=\(spawnGeneration) grid=\(grid.cols)x\(grid.rows)")
    }

    private func handleStderrDrained(generation drainedGeneration: Int) {
        guard drainedGeneration == generation, !stopped else { return }
        stderrDrainedGeneration = drainedGeneration
        if let status = pendingExitStatus {
            pendingExitStatus = nil
            handleRelayExit(generation: drainedGeneration, status: status)
        }
    }

    private func handleRelayTermination(generation exitedGeneration: Int, status: Int32) {
        guard exitedGeneration == generation, !stopped else { return }
        guard stderrDrainedGeneration == exitedGeneration else {
            pendingExitStatus = status
            return
        }
        handleRelayExit(generation: exitedGeneration, status: status)
    }

    private func handleRelayExit(
        generation exitedGeneration: Int,
        status: Int32? = nil,
        forcedExit: TuiManualIOPumpPolicy.RelayExit? = nil
    ) {
        guard exitedGeneration == generation, !stopped else { return }
        inputChannel.setHandle(nil)
        process = nil
        let exit = forcedExit
            ?? TuiManualIOPumpPolicy.relayExit(status: status ?? -1, stderrText: stderrBox.text())
#if DEBUG
        let stderrTail = (stderrBox.text() ?? "").suffix(300).replacingOccurrences(of: "\n", with: " | ")
        log("relay exit \(exit) terminal=\(terminalID.prefix(12)) status=\(status.map(String.init) ?? "nil") stderr=\(stderrTail)")
#else
        log("relay exit \(exit)")
#endif
        switch TuiManualIOPumpPolicy.nextAction(after: exit) {
        case .end:
            state = .ended
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

import CmuxTerminal
import CmuxTuiManualIO
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

/// App-only presentation mapping for the package-owned pump state.
extension TuiManualIOPumpPolicy {
    func overlayPresentation(
        state: TuiManualIOPumpState
    ) -> CloudTerminalReconnectOverlayPolicy.Presentation? {
        switch state {
        case .connecting, .live:
            return nil
        case .reconnecting(let attempt):
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(
                    localized: "tui.overlay.reconnecting.title",
                    defaultValue: "Cloud terminal unavailable"
                ),
                detail: String(
                    localized: "tui.overlay.reconnecting.detail",
                    defaultValue: "Trying to reconnect (attempt \(attempt)). The terminal shows its last state; input is paused."
                ),
                showsProgress: true,
                showsReconnectButton: true
            )
        case .ended:
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(
                    localized: "tui.overlay.ended.title",
                    defaultValue: "Cloud terminal session ended"
                ),
                detail: String(
                    localized: "tui.overlay.ended.detail",
                    defaultValue: "This terminal session has ended. Close the tab, or keep it to read the final screen."
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        case .failed:
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(
                    localized: "tui.overlay.failed.title",
                    defaultValue: "Cloud terminal unavailable"
                ),
                detail: String(
                    localized: "tui.overlay.failed.detail",
                    defaultValue: "This terminal cannot connect. Retry, or close the pane and reopen the terminal from the machine's tree."
                ),
                showsProgress: false,
                showsReconnectButton: true
            )
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
    typealias State = TuiManualIOPumpState

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
    /// Resolves a fresh relay target after the current process or machine link
    /// dies. Cloud panes use this to replace a stale headless-link socket;
    /// local/test panes leave it nil and reuse `target`.
    private let targetProvider: (@Sendable () async throws -> TuiManualIORelayTarget)?
    private let environment: [String: String]
    private let policy: TuiManualIOPumpPolicy
    private let inputChannel: TuiManualIOInputChannel
    /// Injected so tests can run the backoff deterministically. Production
    /// uses the cancellation-aware continuous clock.
    private let sleep: @Sendable (Duration) async throws -> Void

    private weak var surface: TerminalSurface?
    private var process: Process?
    private var spawnTask: Task<Void, Never>?
    private var spawnRequestGeneration = 0
    private var stdoutReader: RemoteTmuxProcessOutputReader?
    private var stdoutTask: Task<Void, Never>?
    private var stderrBox = TuiManualIOStderrBox()
    private var stderrStream: TuiManualIOStderrStream?
    private var retryTask: Task<Void, Never>?
    /// Process termination and pipe EOFs race (termination is not EOF).
    /// Classification waits for the status, the final stderr reason, and all
    /// stdout bytes committed before exit for the current generation.
    private var pendingExitStatus: Int32?
    private var stderrDrainedGeneration = 0
    private var stdoutDrainedGeneration = 0
    /// Fences callbacks from an old relay after a respawn or stop.
    private var generation = 0
    private var stopped = false
    private var everRenderedAttach = false
    private var consecutiveUnexplainedFailures = 0
    private var lastKnownGrid: TuiManualIOGrid?
    private var resizeScheduler = TuiManualIOResizeScheduler()
    private var resizeAckTimeoutTask: Task<Void, Never>?
    /// Liveness bound for a lost or unsupported ack line; treating the
    /// timeout as an ack keeps the pending size flowing on relays that stop
    /// emitting resize diags.
    static let resizeAckTimeout: Duration = .seconds(2)

    deinit {
        spawnTask?.cancel()
        retryTask?.cancel()
        resizeAckTimeoutTask?.cancel()
        stdoutTask?.cancel()
        stdoutReader?.close()
        stderrStream?.close()
        inputChannel.closeHandle()
        process?.terminationHandler = nil
        process?.terminate()
    }

    init(
        binaryPath: String,
        target: TuiManualIORelayTarget,
        terminalID: String,
        environment: [String: String],
        targetProvider: (@Sendable () async throws -> TuiManualIORelayTarget)? = nil,
        policy: TuiManualIOPumpPolicy = TuiManualIOPumpPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.binaryPath = binaryPath
        self.target = target
        self.terminalID = terminalID
        self.environment = environment
        self.targetProvider = targetProvider
        self.policy = policy
        self.inputChannel = TuiManualIOInputChannel(policy: policy)
        self.sleep = sleep
    }

    /// The surface's `manualInputHandler`: runs on Ghostty's IO thread, so
    /// it only touches the lock-guarded input channel.
    nonisolated func makeManualInputHandler() -> @Sendable (TerminalManualInput) -> Void {
        let channel = inputChannel
        let policy = policy
        return { input in
            switch input {
            case .bytes(let bytes):
                channel.sendUserInput(policy.inputLine(bytes: bytes))
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
        surface.onManualGeometryOwnershipChanged = { [weak self] in
            self?.markGeometryOwnershipChanged()
        }
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
    @discardableResult
    func retryNow() -> Bool {
        switch state {
        case .reconnecting, .failed:
            guard !stopped else { return false }
            consecutiveUnexplainedFailures = 0
            retryTask?.cancel()
            retryTask = nil
            cancelPendingSpawn()
            state = .reconnecting(attempt: 1)
            spawnRelay()
            return true
        case .connecting, .live, .ended:
            return false
        }
    }

    /// Tears the pump down (panel closed, app quitting, transfer discard).
    /// The relay sees stdin EOF and detaches cleanly; the daemon terminal
    /// itself stays alive in the machine's session.
    func stop() {
        stopped = true
        cancelPendingSpawn()
        retryTask?.cancel()
        retryTask = nil
        resizeAckTimeoutTask?.cancel()
        resizeAckTimeoutTask = nil
        surface?.onManualGeometryOwnershipChanged = nil
        surface?.onManualSizeApplied = nil
        surface?.onRuntimeReady = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stdoutReader?.close()
        stdoutReader = nil
        stderrStream?.close()
        stderrStream = nil
        inputChannel.closeHandle()
        generation += 1
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    /// Re-asserts this pane as the geometry owner on its next user input.
    /// Selection/focus code calls this after an authoritative focus change.
    func markGeometryOwnershipChanged() {
        inputChannel.markGeometryOwnershipChanged()
    }

    var overlayPresentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        policy.overlayPresentation(state: state)
    }

    // MARK: - Sizing

    private func handleSizingSample(cols: Int, rows: Int) {
        guard !stopped else { return }
        let grid = TuiManualIOGrid(cols: cols, rows: rows)
        lastKnownGrid = grid
        if process == nil, retryTask == nil, case .connecting = state {
            spawnRelay()
            return
        }
        if let send = resizeScheduler.sample(grid) {
            deliverResize(send)
        }
    }

    private func deliverResize(_ grid: TuiManualIOGrid) {
        inputChannel.send(policy.resizeLine(cols: grid.cols, rows: grid.rows))
        startResizeAckTimeout()
    }

    /// The relay reported one resize round trip done (applied, deduplicated,
    /// or errored — all free the channel), or the liveness timeout fired.
    private func handleResizeAcknowledged(generation ackedGeneration: Int) {
        guard ackedGeneration == generation, !stopped else { return }
        resizeAckTimeoutTask?.cancel()
        resizeAckTimeoutTask = nil
        if let next = resizeScheduler.acknowledged() {
            deliverResize(next)
        }
    }

    private func startResizeAckTimeout() {
        let timeoutGeneration = generation
        let sleep = sleep
        resizeAckTimeoutTask?.cancel()
        resizeAckTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.resizeAckTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.log("resize ack timeout generation=\(timeoutGeneration)")
            self?.handleResizeAcknowledged(generation: timeoutGeneration)
        }
    }

    // MARK: - Relay lifecycle

    private func spawnRelay() {
        guard !stopped, surface != nil else { return }
        // Terminal states only leave through retryNow (which transitions
        // back to reconnecting first) or teardown; a straggler retry task
        // or sizing sample must not resurrect the relay.
        if state == .ended || state == .failed { return }
        guard process == nil, spawnTask == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        if let targetProvider {
            spawnRequestGeneration += 1
            let requestGeneration = spawnRequestGeneration
            spawnTask = Task { @MainActor [weak self] in
                do {
                    let resolvedTarget = try await targetProvider()
                    guard let self,
                          !self.stopped,
                          !Task.isCancelled,
                          self.spawnRequestGeneration == requestGeneration else { return }
                    self.spawnTask = nil
                    self.spawnRelay(target: resolvedTarget)
                } catch {
                    guard let self,
                          !self.stopped,
                          self.spawnRequestGeneration == requestGeneration else { return }
                    self.spawnTask = nil
                    self.log("target resolve failed: \(error)")
                    // A link-manager failure is a transport outage, not a
                    // broken relay binary. Keep the pane reconnecting until
                    // the machine link can be recreated.
                    self.scheduleRetry()
                }
            }
            return
        }
        spawnRelay(target: target)
    }

    private func spawnRelay(target: TuiManualIORelayTarget) {
        guard !stopped, let surface else { return }
        guard process == nil else { return }
        generation += 1
        let spawnGeneration = generation
        let grid = lastKnownGrid ?? TuiManualIOGrid(cols: 80, rows: 24)
        resizeScheduler.seed(delivered: grid)
        resizeAckTimeoutTask?.cancel()
        resizeAckTimeoutTask = nil

        // A respawned relay replays the daemon terminal from scratch; reset
        // the surface first so the replay replaces the stale frame instead
        // of stacking on it.
        if everRenderedAttach {
            surface.processRemoteOutput(policy.resyncReset)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = policy.relayArguments(
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
        stderrDrainedGeneration = 0
        stdoutDrainedGeneration = 0
        // Streaming drain: it continuously empties the pipe (a full pipe
        // would wedge the relay), surfaces per-resize diag lines as acks
        // for the resize scheduler while the relay runs, and EOF is the
        // only signal that the final exit-reason line has landed.
        stderrStream?.close()
        stderrStream = TuiManualIOStderrStream(
            handle: stderrPipe.fileHandleForReading,
            box: stderrBox,
            onResizeDiag: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleResizeAcknowledged(generation: spawnGeneration)
                }
            },
            onEOF: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleStderrDrained(generation: spawnGeneration)
                }
            }
        )

        let reader = RemoteTmuxProcessOutputReader(
            label: "cmux.tuiManualIO.stdout",
            maxPendingChunks: 512,
            maxPendingBytes: 8 * 1024 * 1024,
            onOverflow: { [weak self] in
                // The reader invokes this callback from its descriptor
                // queue. Hop explicitly to the pump's actor and fence the
                // callback against a newer generation before mutating state.
                Task { @MainActor [weak self] in
                    guard let self,
                          self.generation == spawnGeneration,
                          !self.stopped else { return }
                    // The surface stopped consuming; treat like a dead relay
                    // so a respawn resyncs from a bounded replay.
                    self.handleRelayExit(generation: spawnGeneration, forcedExit: .daemonLost)
                }
            }
        )
        stdoutReader?.close()
        stdoutReader = reader
        stdoutTask?.cancel()
        stdoutTask = Task { @MainActor [weak self] in
            for await chunk in reader.stream {
                guard let self, self.generation == spawnGeneration, !self.stopped else {
                    reader.release(chunk)
                    break
                }
                // Once termination classified this generation as ended or
                // failed, the reader can still yield bytes that were already
                // buffered in the pipe. They are stale and must not revive
                // the overlay or append after the terminal's final frame.
                guard self.policy.acceptsRelayOutput(state: self.state) else {
                    reader.release(chunk)
                    break
                }
                self.surface?.processRemoteOutput(chunk)
                reader.release(chunk)
                self.everRenderedAttach = true
                // The first replay chunk is not proof of stable liveness.
                // Reset the failure streak only after output arrives while
                // the relay was already live.
                if self.state == .live {
                    self.consecutiveUnexplainedFailures = 0
                }
                if self.state == .connecting || self.isReconnecting {
                    self.state = .live
                }
            }
            reader.close()
            self?.handleStdoutDrained(generation: spawnGeneration)
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
            stderrStream?.close()
            stderrStream = nil
            noteUnexplainedFailureThenRetryOrFail()
            return
        }
        self.process = process
        inputChannel.setHandle(stdinPipe.fileHandleForWriting)
        reader.attach(to: stdoutPipe.fileHandleForReading)
        log("relay spawned generation=\(spawnGeneration) grid=\(grid.cols)x\(grid.rows)")
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    private func cancelPendingSpawn() {
        spawnRequestGeneration += 1
        spawnTask?.cancel()
        spawnTask = nil
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
        stdoutReader?.processDidExit()
        finishRelayIfDrained(generation: exitedGeneration)
    }

    private func finishRelayIfDrained(generation drainedGeneration: Int) {
        guard drainedGeneration == generation,
              !stopped,
              stderrDrainedGeneration == drainedGeneration,
              stdoutDrainedGeneration == drainedGeneration,
              let status = pendingExitStatus else { return }
        pendingExitStatus = nil
        handleRelayExit(generation: drainedGeneration, status: status)
    }

    private func handleRelayExit(
        generation exitedGeneration: Int,
        status: Int32? = nil,
        forcedExit: TuiManualIOPumpPolicy.RelayExit? = nil
    ) {
        guard exitedGeneration == generation, !stopped else { return }
        if forcedExit != nil {
            // Overflow means the surface cannot keep up. Stop the relay
            // before scheduling a replacement, and fence late callbacks
            // from the terminated process.
            process?.terminationHandler = nil
            process?.terminate()
        }
        // Retire every callback from this process before changing state. A
        // delayed output chunk must not turn `.reconnecting`, `.ended`, or
        // `.failed` back into `.live`.
        generation += 1
        let stderrText = stderrBox.text()
        stdoutTask?.cancel()
        stdoutTask = nil
        stdoutReader?.close()
        stdoutReader = nil
        stderrStream?.close()
        stderrStream = nil
        inputChannel.setHandle(nil)
        process = nil
        // A dead relay has no resize channel; the respawn reseeds the
        // scheduler from its spawn grid.
        resizeAckTimeoutTask?.cancel()
        resizeAckTimeoutTask = nil
        resizeScheduler.reset()
        let exit = forcedExit
            ?? policy.relayExit(status: status ?? -1, stderrText: stderrText)
#if DEBUG
        let stderrTail = (stderrText ?? "").suffix(300).replacingOccurrences(of: "\n", with: " | ")
        log("relay exit \(exit) terminal=\(terminalID.prefix(12)) status=\(status.map(String.init) ?? "nil") stderr=\(stderrTail)")
#else
        log("relay exit \(exit)")
#endif
        switch policy.nextAction(after: exit) {
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
            >= policy.maxConsecutiveUnexplainedFailures {
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
        let delay = policy.retryDelay(attempt: attempt)
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

/// GCD-driven stderr reader for one relay: accumulates raw bytes in the
/// exit-classification box AND surfaces each complete `{"diag":{"resize":…}}`
/// line as a resize ack while the relay runs. `readabilityHandler` runs on a
/// GCD queue and costs the cooperative pool nothing (same rationale as
/// `CloudLinkPipe`); EOF is still the only signal that the final exit-reason
/// line has landed.
final class TuiManualIOStderrStream: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pendingLine = Data()

    init(
        handle: FileHandle,
        box: TuiManualIOStderrBox,
        onResizeDiag: @escaping @Sendable () -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                onEOF()
                return
            }
            box.append(data)
            self?.scanLines(data, onResizeDiag: onResizeDiag)
        }
    }

    /// Splits the byte stream into complete lines and fires the ack callback
    /// for each resize diag. Partial trailing lines wait for the next chunk;
    /// the final (exit) line needs no scan, EOF classification owns it.
    private func scanLines(_ data: Data, onResizeDiag: @Sendable () -> Void) {
        lock.lock()
        pendingLine.append(data)
        var lines: [Data] = []
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            lines.append(Data(pendingLine[pendingLine.startIndex..<newline]))
            pendingLine = Data(pendingLine[pendingLine.index(after: newline)...])
        }
        // Bound the buffer against a relay that misbehaves and never prints
        // a newline; diag and exit lines are all short.
        if pendingLine.count > 64 * 1024 {
            pendingLine.removeFirst(pendingLine.count - 64 * 1024)
        }
        lock.unlock()
        for line in lines {
            if line.range(of: Data(#""diag""#.utf8)) != nil,
               line.range(of: Data(#""resize""#.utf8)) != nil {
                onResizeDiag()
            }
        }
    }

    func close() {
        lock.lock()
        let target = handle
        handle = nil
        lock.unlock()
        target?.readabilityHandler = nil
    }

    deinit {
        close()
    }
}

/// Lock-guarded stderr accumulator: the relay prints its machine-readable
/// exit reason as the final stderr line.
final class TuiManualIOStderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    deinit {}

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
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }
}

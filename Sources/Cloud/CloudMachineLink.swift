import Foundation

/// Bounded recovery for the event side channel. The command socket remains usable while the
/// feed is repaired, but a broken child process must never create an infinite spawn loop.
struct CloudMachineLinkEventsRecoveryPolicy: Sendable, Equatable {
    static let standard = Self(delays: [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
    ], stabilityWindow: .seconds(10))

    let delays: [Duration]
    /// A stream must carry an accepted event for this long before prior failures
    /// stop counting. This prevents a child that emits one event and exits from
    /// resetting the bounded recovery budget forever.
    let stabilityWindow: Duration

    init(delays: [Duration], stabilityWindow: Duration = .seconds(10)) {
        precondition(!delays.isEmpty)
        precondition(delays.allSatisfy { $0 > .zero })
        precondition(stabilityWindow > .zero)
        self.delays = delays
        self.stabilityWindow = stabilityWindow
    }

    func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

/// One headless cmux-tui link to a cloud machine's daemon: a `remote connect --headless`
/// client process whose local mux socket the app drives for snapshots, events, and
/// terminal creation. The pane's own `vm-tui-connect` link is separate; this one belongs
/// to the sidebar and the `vm.*` tree methods and never touches a tty.
///
/// Lifecycle: `connect` spawns the client and resolves once the first
/// `connection-snapshot` line names the socket; the process is kept until `disconnect`
/// or until it exits on its own (machine slept, route expired), which flips the state
/// and ends the `changes` stream so the owner can re-link on demand.
actor CloudMachineLink {
    /// Stable reason emitted when the bounded event-feed recovery budget is spent.
    /// Providers use the same value when deciding whether a later healthy stream
    /// has cleared the transport warning.
    nonisolated static let eventsRecoveryExhaustedReason = "events_recovery_exhausted"

    /// Recovery state is one phase so an exhausted stream cannot be mistaken for
    /// a snapshot-only stream or a fresh connection. The attempt is consecutive
    /// until an accepted stream stays healthy for the policy's stability window.
    enum EventsRecoveryPhase: Equatable {
        case healthy
        case recovering(attempt: Int)
        /// The retry budget is spent, but one authoritative full snapshot may
        /// make one final stream-start attempt without resetting that budget.
        case exhausted(canResumeFromSnapshot: Bool)
        /// A snapshot consumed the one-shot restart allowance. It must become
        /// healthy before another failure can be forgiven.
        case snapshotRecovery
        case snapshotOnly
    }

    /// A manual reader restart is a transport operation, not a new connection.
    /// It may preserve a healthy or in-progress recovery phase, but it cannot
    /// bypass an exhausted budget or resume an unversioned snapshot stream.
    nonisolated static func canRestartEventsSubscription(for phase: EventsRecoveryPhase) -> Bool {
        switch phase {
        case .healthy, .recovering, .snapshotRecovery:
            return true
        case .exhausted, .snapshotOnly:
            return false
        }
    }

    /// One notification from the daemon session stream. The provider validates
    /// its cursor before it can replace the installed `CloudVMState`.
    enum Change: Sendable, Equatable {
        case connected
        case snapshot(cursor: CloudVMCursor, resetReason: String?, payload: Data)
        case delta(cursor: CloudVMCursor, previousRevision: UInt64, revision: UInt64, payload: Data)
        case streamEnded(reason: String, cursor: CloudVMCursor?)
        /// An unknown item is a synchronization barrier. Ignoring it could make
        /// the following known delta appear valid after a state change was lost.
        case unknown(cursor: CloudVMCursor?)
    }

    struct Connected: Sendable, Equatable {
        let socketPath: String
        let session: String
    }

    /// The first thing the link process tells us: a socket line, stdout closing
    /// without one, or the connect deadline passing.
    private enum LinkFirstLine: Sendable {
        case socket(String)
        case ended
        case timedOut
    }

    enum LinkError: Error, LocalizedError {
        case clientMissing
        case spawnFailed(String)
        case exited(status: Int32, output: String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .clientMissing:
                return "No cmux-tui client is bundled with this build (Contents/Resources/bin/cmux-tui) and CMUX_TUI_CLIENT is unset."
            case .spawnFailed(let detail):
                return "cmux-tui could not be started: \(detail)"
            case .exited(let status, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                return "cmux-tui link exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
            case .timedOut:
                return "cmux-tui link did not report a socket within the connect timeout."
            }
        }
    }

    let machineID: String
    private let clientURL: URL
    private let paths: CloudTuiClientPaths

    private(set) var state: SurfaceLinkState = .connecting
    private(set) var lastError: String?

    /// Human-readable text for a link failure. Typed cmux errors describe
    /// themselves (`VMClientError` is `CustomStringConvertible`, the link and
    /// manager errors are `LocalizedError`); only foreign errors fall back to
    /// Foundation's "The operation couldn't be completed. (… error 1.)".
    nonisolated static func errorText(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        // Swift errors print their `description` (or case name) here; a real
        // NSError prints "Error Domain=… Code=…", where localizedDescription
        // is the readable form.
        let described = String(describing: error)
        if described.isEmpty || described.hasPrefix("Error Domain=") {
            return error.localizedDescription
        }
        return described
    }
    private(set) var connected: Connected?

    // Foundation `Process` and its pipes are actor-isolated state; every callback hops
    // back into the actor through a Task, so nothing else touches them.
    private var process: Process?
    private var processExit: CloudLinkFirstValue<Int32>?
    private var eventsProcess: Process?
    private var eventsProcessExit: CloudLinkFirstValue<Int32>?
    private var eventsSubscriptionID: UUID?
    private var eventsReaderTask: Task<Void, Never>?
    private var eventsCursor: CloudVMCursor?
    private let eventsRecoveryClock: any Clock<Duration>
    private let eventsRecoveryPolicy: CloudMachineLinkEventsRecoveryPolicy
    private var eventsRecoveryTask: Task<Void, Never>?
    private var eventsStabilityTask: Task<Void, Never>?
    private var eventsRecoveryPhase: EventsRecoveryPhase = .healthy
    private var stderrTail: [String] = []
    /// Releases this link's claim on the app's WireGuard hub; runs once when the link ends.
    private var releaseHubLease: (@Sendable () async -> Void)?

    /// The newest change is buffered. If pressure drops an earlier delta, the next
    /// `previous_revision` check detects the gap and forces a complete snapshot.
    let changes: AsyncStream<Change>
    private let changesContinuation: AsyncStream<Change>.Continuation

    init(
        machineID: String,
        clientURL: URL,
        paths: CloudTuiClientPaths,
        eventsRecoveryClock: any Clock<Duration> = ContinuousClock(),
        eventsRecoveryPolicy: CloudMachineLinkEventsRecoveryPolicy = .standard
    ) {
        self.machineID = machineID
        self.clientURL = clientURL
        self.paths = paths
        self.eventsRecoveryClock = eventsRecoveryClock
        self.eventsRecoveryPolicy = eventsRecoveryPolicy
        (changes, changesContinuation) = AsyncStream<Change>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var isConnected: Bool { connected != nil && state == .connected }

    /// Spawns the headless client against `route` and waits for its local socket.
    ///
    /// `carrier` dials the machine's trusted listener with no enrollment; false presents
    /// the stored device key instead. `wireguardHubSocket` routes the client through the
    /// app's WireGuard hub for a machine on the private network; `releaseHubLease` is
    /// called exactly once when the link ends (disconnect, exit, or a failed connect), so
    /// the hub can idle out.
    func connect(
        route: String,
        session: String,
        carrier: Bool = false,
        timeout: Duration = .seconds(60),
        wireguardHubSocket: String? = nil,
        releaseHubLease: (@Sendable () async -> Void)? = nil
    ) async throws -> Connected {
        if let connected, state == .connected {
            await releaseHubLease?()
            return connected
        }
        self.releaseHubLease = releaseHubLease
        eventsCursor = nil
        resetEventsRecovery()
        try paths.ensureStateDir()
        let process = Process()
        process.executableURL = clientURL
        process.arguments = CloudTuiCommandLine.linkArguments(
            route: route,
            deviceName: CloudTuiClientPaths.deviceName(),
            stateDir: paths.stateDir.path,
            carrier: carrier,
            wireguardHubSocket: wireguardHubSocket
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.stateDir.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let processExit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            processExit.resolve(status)
            Task { await self?.linkProcessDidExit(terminated, status: status) }
        }
        state = .connecting
        lastError = nil
        do {
            try process.run()
        } catch {
            state = .error
            lastError = Self.errorText(error)
            await releaseHubLeaseOnce()
            throw LinkError.spawnFailed(error.localizedDescription)
        }
        self.process = process
        self.processExit = processExit
        drainStderr(stderr.fileHandleForReading)

        // The first connection-snapshot line names the socket; later lines only update
        // transport topology and are ignored — but stdout keeps draining for the
        // process's whole life so the client never blocks on a full pipe.
        let firstSocket = CloudLinkFirstValue<String>()
        let stdoutLines = CloudLinkPipe.lines(from: stdout.fileHandleForReading)
        Task.detached {
            for await line in stdoutLines {
                if let socket = CmuxTuiSnapshotParser.localSocket(fromLinkLine: line) {
                    firstSocket.resolve(socket)
                }
            }
            firstSocket.resolve(nil)
        }
        let socketPath: String
        do {
            socketPath = try await withThrowingTaskGroup(of: LinkFirstLine.self) { group in
                group.addTask { (await firstSocket.result).map(LinkFirstLine.socket) ?? .ended }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }
                defer { group.cancelAll() }
                switch try await group.next() {
                case .socket(let socket)?:
                    return socket
                case .ended?:
                    // stdout closed before a socket line: the client exited (an older
                    // client rejecting a flag, a refused dial). Report that exit and its
                    // stderr, not the deadline it never reached.
                    await Self.terminateAndWait(process, exit: processExit)
                    throw LinkError.exited(
                        status: process.terminationStatus,
                        output: stderrTail.joined(separator: "\n")
                    )
                case .timedOut?, nil:
                    throw LinkError.timedOut
                }
            }
            guard process.isRunning else {
                throw LinkError.exited(status: process.terminationStatus, output: stderrTail.joined(separator: "\n"))
            }
        } catch {
            state = .error
            lastError = Self.errorText(error)
            await Self.terminateAndWait(process, exit: processExit)
            if self.process === process {
                self.process = nil
                self.processExit = nil
            }
            await releaseHubLeaseOnce()
            throw error
        }
        let connected = Connected(socketPath: socketPath, session: session)
        self.connected = connected
        state = .connected
        await startEventsSubscription(socketPath: socketPath, cursor: nil)
        changesContinuation.yield(.connected)
        return connected
    }

    func disconnect() async {
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
        state = .unavailable
        connected = nil
        changesContinuation.finish()
        if let eventsProcess, let eventsProcessExit {
            await Self.terminateAndWait(eventsProcess, exit: eventsProcessExit)
            if self.eventsProcess === eventsProcess {
                self.eventsProcess = nil
                self.eventsProcessExit = nil
            }
        }
        if let process, let processExit {
            await Self.terminateAndWait(process, exit: processExit)
            if self.process === process {
                self.process = nil
                self.processExit = nil
            }
        }
        await releaseHubLeaseOnce()
    }

    /// Records a cursor only after the owner has accepted the corresponding
    /// snapshot or delta. The transport must not advance this value while it
    /// is merely decoding a line: a malformed or dropped event is not state.
    func setEventsCursor(_ cursor: CloudVMCursor?) {
        guard let cursor else { return }
        if let current = eventsCursor,
           current.generation == cursor.generation,
           current.revision >= cursor.revision {
            return
        }
        let acceptedFromActiveStream = eventsSubscriptionID != nil
        eventsCursor = cursor
        // The owner accepted a valid event. It starts the success window, but one
        // event is not enough to forgive a repeatedly dying child process.
        if acceptedFromActiveStream, let subscriptionID = eventsSubscriptionID {
            scheduleEventsStabilityReset(subscriptionID: subscriptionID)
        }
    }

    /// Replaces the resume point exactly at a recovery boundary. Unlike
    /// `setEventsCursor`, this also accepts nil and a lower revision because a
    /// new generation or an explicit snapshot is authoritative.
    private func replaceEventsCursor(_ cursor: CloudVMCursor?) {
        eventsCursor = cursor
    }

    /// Reopens the event reader from the last accepted cursor. A stream can end
    /// on journal overflow, daemon restart, or a transient local socket close.
    func restartEventsSubscription(from cursor: CloudVMCursor? = nil) async {
        guard state == .connected, let socketPath = connected?.socketPath else { return }
        guard Self.canRestartEventsSubscription(for: eventsRecoveryPhase) else { return }
        // Cancel a delayed retry owned by the old reader, but keep its phase and
        // attempt count. The next failed reader must consume the next budget slot.
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        replaceEventsCursor(cursor ?? eventsCursor)
        _ = await startEventsSubscription(socketPath: socketPath, cursor: eventsCursor)
    }

    /// Marks a snapshot as the new synchronization boundary and resumes the event
    /// feed when the previous feed exhausted its recovery budget. A healthy active
    /// feed is left in place, so accepting a normal snapshot does not create a
    /// second reader or lose events between two subscriptions.
    @discardableResult
    func resumeEventsSubscription(from cursor: CloudVMCursor) async -> Bool {
        // A versioned snapshot is allowed to leave snapshot-only mode. Routine
        // refreshes must not reset an exhausted recovery budget, or a broken
        // daemon would be respawned forever by each refresh.
        let leavingSnapshotOnly = eventsRecoveryPhase == .snapshotOnly
        let hasSnapshotRecoveryAllowance: Bool
        if case .exhausted(canResumeFromSnapshot: true) = eventsRecoveryPhase {
            hasSnapshotRecoveryAllowance = true
        } else {
            hasSnapshotRecoveryAllowance = false
        }
        if leavingSnapshotOnly { resetEventsRecovery() }
        replaceEventsCursor(cursor)
        guard state == .connected, let socketPath = connected?.socketPath else { return false }
        // A live reader is already a healthy synchronization path. Returning
        // true lets the owner clear a stale warning without starting a second
        // process or dropping the current stream.
        if eventsSubscriptionID != nil { return true }
        guard eventsRecoveryTask == nil else { return false }
        if hasSnapshotRecoveryAllowance {
            // A full snapshot is an ordering boundary, not a reason to erase
            // the transport failure budget. Consume the one-shot restart now.
            eventsRecoveryPhase = .snapshotRecovery
        }
        guard eventsRecoveryPhase == .healthy || eventsRecoveryPhase == .snapshotRecovery else { return false }
        return await startEventsSubscription(socketPath: socketPath, cursor: eventsCursor)
    }

    /// Stops the journal reader when the daemon only provides an unversioned
    /// snapshot. The command socket remains usable for reads, while the missing
    /// cursor prevents safe delta ordering and compare-and-swap mutations. A
    /// later versioned snapshot can call `resumeEventsSubscription` to re-enable
    /// the feed. Recovery remains bounded until a stable stream or a new link
    /// connection establishes a fresh boundary.
    func suspendEventsSubscription() {
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        eventsProcess?.terminate()
        eventsProcess = nil
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .snapshotOnly
    }

    /// Runs one cmux-tui command against the link's socket and returns its stdout.
    func run(arguments: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        let process = Process()
        process.executableURL = clientURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Pipes drain on GCD (``CloudLinkPipe``) so a chatty command cannot deadlock on a
        // full pipe and no cooperative thread sits in read(2) or waitpid(2); the exit
        // arrives through the termination handler. A deadline terminates the child,
        // which ends both drains with a non-zero status.
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { exited in exit.resolve(exited.terminationStatus) }
        try process.run()
        async let outData = CloudLinkPipe.readToEnd(stdout.fileHandleForReading)
        async let errData = CloudLinkPipe.readToEnd(stderr.fileHandleForReading)
        // `CloudLinkFirstValue.result` is cancellation-aware. Wait for it from a detached
        // task so cancellation cannot release a still-running Foundation `Process`.
        // `NSConcreteTask` aborts the whole app when that happens. Every return path below
        // first terminates, then observes the real child exit.
        let exitTask = Task.detached { await exit.result }
        let outcome = await withTaskCancellationHandler {
            await withTaskGroup(of: CloudLinkCommandOutcome.self) { group in
                group.addTask {
                    .exited(await exitTask.value ?? -1)
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    } catch {
                        return .cancelled
                    }
                }
                let first = await group.next() ?? .cancelled
                switch first {
                case .exited:
                    break
                case .timedOut, .cancelled:
                    if process.isRunning { process.terminate() }
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // The task group does not return until its exit waiter observes termination.
        // Reading terminationStatus is now safe on every path.
        let status = process.terminationStatus
        let out = await outData
        let err = await errData
        if Task.isCancelled || outcome == .cancelled { throw CancellationError() }
        if outcome == .timedOut { throw LinkError.timedOut }
        guard status == 0 else {
            let text = String(data: err, encoding: .utf8) ?? ""
            let fallback = String(data: out, encoding: .utf8) ?? ""
            throw LinkError.exited(status: status, output: text.isEmpty ? fallback : text)
        }
        return out
    }

    // MARK: - internals

    @discardableResult
    private func startEventsSubscription(socketPath: String, cursor: CloudVMCursor?) async -> Bool {
        guard !socketPath.isEmpty else { return false }
        cancelEventsStabilityReset()
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        // Wait for the previous events child to exit before spawning its replacement,
        // so two readers never race on the same socket.
        if let eventsProcess, let eventsProcessExit {
            await Self.terminateAndWait(eventsProcess, exit: eventsProcessExit)
            if self.eventsProcess === eventsProcess {
                self.eventsProcess = nil
                self.eventsProcessExit = nil
            }
        }
        let subscriptionID = UUID()
        eventsSubscriptionID = subscriptionID
        let process = Process()
        process.executableURL = clientURL
        process.arguments = CloudTuiCommandLine.eventsArguments(socketPath: socketPath, cursor: cursor)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { [weak self] terminated in
            exit.resolve(terminated.terminationStatus)
            Task { await self?.eventsProcessDidExit(terminated) }
        }
        do {
            try process.run()
        } catch {
            eventsSubscriptionID = nil
            changesContinuation.yield(.streamEnded(reason: "events_spawn_failed", cursor: eventsCursor))
            scheduleEventsRecovery()
            return false
        }
        eventsProcess = process
        eventsProcessExit = exit
        let lines = CloudLinkPipe.lines(from: stdout.fileHandleForReading)
        eventsReaderTask = Task.detached { [weak self] in
            var receivedStreamEnd = false
            for await line in lines where !line.isEmpty {
                let change = Self.parseChangeLine(line)
                if case .streamEnded = change { receivedStreamEnd = true }
                await self?.eventChange(change, subscriptionID: subscriptionID)
            }
            await self?.eventReaderDidEnd(subscriptionID: subscriptionID, receivedStreamEnd: receivedStreamEnd)
        }
        return true
    }

    private func eventChange(_ change: Change, subscriptionID: UUID) {
        guard eventsSubscriptionID == subscriptionID else { return }
        switch change {
        case .snapshot, .delta:
            // The provider decides whether the payload is valid and contiguous.
            // It calls `setEventsCursor` after installing the derived state.
            break
        case .streamEnded(let reason, let cursor):
            // A stream-end cursor is only a transport observation. Advancing to
            // it here could skip journal entries when recovery is required.
            changesContinuation.yield(.streamEnded(reason: reason, cursor: cursor))
            finishEventsSubscription(subscriptionID: subscriptionID, reason: nil)
            return
        case .unknown:
            // Unknown data is a barrier. Its cursor cannot be trusted because the
            // missing item may itself have changed the graph.
            break
        case .connected:
            break
        }
        changesContinuation.yield(change)
    }

    private func eventReaderDidEnd(subscriptionID: UUID, receivedStreamEnd: Bool) {
        guard eventsSubscriptionID == subscriptionID else { return }
        finishEventsSubscription(
            subscriptionID: subscriptionID,
            reason: receivedStreamEnd ? nil : "eof"
        )
    }

    /// Ends one event child and schedules its single bounded recovery owner. The subscription
    /// UUID makes late reader callbacks harmless after a replacement has started.
    private func finishEventsSubscription(subscriptionID: UUID, reason: String?) {
        guard eventsSubscriptionID == subscriptionID else { return }
        cancelEventsStabilityReset()
        eventsSubscriptionID = nil
        eventsReaderTask = nil
        eventsProcess?.terminate()
        eventsProcess = nil
        if let reason {
            changesContinuation.yield(.streamEnded(reason: reason, cursor: eventsCursor))
        }
        scheduleEventsRecovery()
    }

    private func resetEventsRecovery() {
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
    }

    private func scheduleEventsRecovery() {
        guard state == .connected,
              connected != nil,
              eventsSubscriptionID == nil,
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: true),
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: false),
              eventsRecoveryPhase != .snapshotOnly,
              eventsRecoveryTask == nil
        else { return }

        let nextAttempt: Int
        if case .snapshotRecovery = eventsRecoveryPhase {
            eventsRecoveryPhase = .exhausted(canResumeFromSnapshot: false)
            changesContinuation.yield(.streamEnded(reason: Self.eventsRecoveryExhaustedReason, cursor: eventsCursor))
            return
        } else if case .recovering(let attempt) = eventsRecoveryPhase {
            nextAttempt = attempt + 1
        } else {
            nextAttempt = 1
        }
        guard let delay = eventsRecoveryPolicy.delay(forAttempt: nextAttempt) else {
            // The first capped run may be retried once after a valid full
            // snapshot. A later capped run has already consumed that allowance.
            let canResumeFromSnapshot: Bool
            if case .recovering(let attempt) = eventsRecoveryPhase {
                canResumeFromSnapshot = attempt == eventsRecoveryPolicy.delays.count
            } else {
                canResumeFromSnapshot = false
            }
            eventsRecoveryPhase = .exhausted(canResumeFromSnapshot: canResumeFromSnapshot)
            changesContinuation.yield(.streamEnded(reason: Self.eventsRecoveryExhaustedReason, cursor: eventsCursor))
            return
        }
        eventsRecoveryPhase = .recovering(attempt: nextAttempt)
        let clock = eventsRecoveryClock
        let socketPath = connected!.socketPath
        eventsRecoveryTask = Task { [weak self, clock, delay, socketPath] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recoverEventsSubscription(socketPath: socketPath)
        }
    }

    private func recoverEventsSubscription(socketPath: String) async {
        eventsRecoveryTask = nil
        guard state == .connected,
              connected?.socketPath == socketPath,
              eventsSubscriptionID == nil,
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: true),
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: false),
              eventsRecoveryPhase != .snapshotRecovery,
              eventsRecoveryPhase != .snapshotOnly
        else { return }
        _ = await startEventsSubscription(socketPath: socketPath, cursor: eventsCursor)
    }

    /// Starts a cancellable healthy-stream window after the owner accepts an
    /// event. The subscription ID prevents a late timer from forgiving a newer
    /// stream after this one has ended.
    private func scheduleEventsStabilityReset(subscriptionID: UUID) {
        guard eventsStabilityTask == nil,
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: true),
              eventsRecoveryPhase != .exhausted(canResumeFromSnapshot: false),
              eventsRecoveryPhase != .snapshotOnly
        else { return }
        let clock = eventsRecoveryClock
        let stabilityWindow = eventsRecoveryPolicy.stabilityWindow
        eventsStabilityTask = Task { [weak self, clock, stabilityWindow, subscriptionID] in
            do {
                try await clock.sleep(for: stabilityWindow)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.markEventsStable(subscriptionID: subscriptionID)
        }
    }

    private func cancelEventsStabilityReset() {
        eventsStabilityTask?.cancel()
        eventsStabilityTask = nil
    }

    private func markEventsStable(subscriptionID: UUID) {
        guard eventsSubscriptionID == subscriptionID else { return }
        eventsStabilityTask = nil
        eventsRecoveryPhase = .healthy
    }

    private func drainStderr(_ handle: FileHandle) {
        let lines = CloudLinkPipe.lines(from: handle)
        Task.detached { [weak self] in
            for await line in lines {
                await self?.recordStderr(line)
            }
        }
    }

    private func recordStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
    }

    private func linkProcessDidExit(_ exitedProcess: Process, status: Int32) async {
        guard process === exitedProcess else { return }
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
        if let eventsProcess, let eventsProcessExit {
            await Self.terminateAndWait(eventsProcess, exit: eventsProcessExit)
            if self.eventsProcess === eventsProcess {
                self.eventsProcess = nil
                self.eventsProcessExit = nil
            }
        }
        process = nil
        processExit = nil
        connected = nil
        if state != .unavailable {
            state = status == 0 ? .unavailable : .error
            lastError = status == 0 ? nil : LinkError.exited(status: status, output: stderrTail.joined(separator: "\n")).errorDescription
        }
        changesContinuation.yield(.streamEnded(reason: "link_exit", cursor: nil))
        changesContinuation.finish()
        await releaseHubLeaseOnce()
    }

    private func eventsProcessDidExit(_ exitedProcess: Process) {
        guard eventsProcess === exitedProcess else { return }
        eventsProcess = nil
        eventsProcessExit = nil
    }

    /// Foundation aborts if a running `Process` is released. Keep a detached exit
    /// waiter alive because the caller can already be cancelled when cleanup starts.
    private nonisolated static func terminateAndWait(
        _ process: Process,
        exit: CloudLinkFirstValue<Int32>
    ) async {
        let exitTask = Task.detached { await exit.result }
        if process.isRunning { process.terminate() }
        _ = await exitTask.value
    }

    private func releaseHubLeaseOnce() async {
        guard let release = releaseHubLease else { return }
        releaseHubLease = nil
        await release()
    }

    /// Parses the public `session current events --jsonl` envelope. Complete
    /// snapshot and delta items are retained as canonical JSON so new daemon fields
    /// survive until this app learns their typed form.
    nonisolated static func parseChangeLine(_ line: String) -> Change {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown(cursor: nil) }

        if (root["type"] as? String) == "stream_end" {
            let cursor = (root["cursor"] as? [String: Any]).flatMap(CloudVMCursor.init(wire:))
            return .streamEnded(reason: (root["reason"] as? String) ?? "unknown", cursor: cursor)
        }

        // The documented form wraps the event in `item`. Older JSONL clients
        // emitted the inner item, so accepting both preserves wire compatibility.
        let item = (root["item"] as? [String: Any]) ?? root
        let cursor = (item["cursor"] as? [String: Any]).flatMap(CloudVMCursor.init(wire:))
            ?? (root["cursor"] as? [String: Any]).flatMap(CloudVMCursor.init(wire:))
        guard let kind = item["kind"] as? String else { return .unknown(cursor: cursor) }

        switch kind {
        case "snapshot":
            guard var snapshot = item["snapshot"] as? [String: Any],
                  let cursor else { return .unknown(cursor: cursor) }
            // Some client versions put the cursor only on the event envelope.
            // Materialize it into the snapshot bytes so the state parser sees
            // one self-describing document.
            if snapshot["cursor"] == nil || snapshot["cursor"] is NSNull {
                snapshot["cursor"] = [
                    "generation": cursor.generation,
                    "revision": String(cursor.revision),
                ] as [String: Any]
            }
            guard let payload = canonicalJSONData(snapshot) else {
                return .unknown(cursor: cursor)
            }
            return .snapshot(cursor: cursor, resetReason: item["reset_reason"] as? String, payload: payload)
        case "delta":
            guard let cursor,
                  let previousRevision = decimal(item["previous_revision"]),
                  let revision = decimal(item["revision"]),
                  item["changes"] is [[String: Any]],
                  let payload = canonicalJSONData(item)
            else { return .unknown(cursor: cursor) }
            return .delta(cursor: cursor, previousRevision: previousRevision, revision: revision, payload: payload)
        default:
            return .unknown(cursor: cursor)
        }
    }

    private nonisolated static func decimal(_ raw: Any?) -> UInt64? {
        CloudWireNumber.unsigned(raw)
    }

    private nonisolated static func canonicalJSONData(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

}

private enum CloudLinkCommandOutcome: Sendable, Equatable {
    case exited(Int32)
    case timedOut
    case cancelled
}

/// GCD-driven reading of the link's child-process pipes. `FileHandle.bytes.lines` and
/// `readDataToEndOfFile()` park a cooperative thread in read(2) for as long as the pipe
/// stays open; every linked machine held three that way (link stdout, link stderr, the
/// events stream) and each `run` three more, so a few machines exhausted the pool —
/// `Task.sleep` deadlines stopped firing, links sat in "connecting" for minutes past
/// their timeout, and every socket command crawled. `readabilityHandler` runs on a GCD
/// queue and costs the pool nothing.
enum CloudLinkPipe {
    /// Raw chunks as they arrive; ends at EOF. One consumer.
    static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Lines (without their newline; a trailing CR is dropped) as they arrive; a final
    /// unterminated line is delivered at EOF. One consumer.
    static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Everything up to EOF.
    static func readToEnd(_ handle: FileHandle) async -> Data {
        var data = Data()
        for await chunk in chunks(from: handle) {
            data.append(chunk)
        }
        return data
    }

    /// Splits a byte stream into lines; only ever touched from the handle's GCD queue.
    static func splitLines(_ data: Data) -> (lines: [String], rest: Data) {
        var lines: [String] = []
        var pending = data
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            pending = pending[pending.index(after: newline)...]
        }
        return (lines, Data(pending))
    }

    private final class LineBuffer {
        private var pending = Data()

        func append(_ data: Data) -> [String] {
            pending.append(data)
            let split = CloudLinkPipe.splitLines(pending)
            pending = split.rest
            return split.lines
        }

        func flush() -> String? {
            defer { pending = Data() }
            guard !pending.isEmpty else { return nil }
            var line = String(decoding: pending, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }
}

/// A value resolved at most once from a GCD callback and awaited from Swift concurrency;
/// `resolve(nil)` finishes it without a value (EOF before the line, no exit status).
final class CloudLinkFirstValue<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case done(Value?)
    }

    // A GCD or Process callback and task cancellation can race to resume one
    // continuation. This short lock protects only that synchronous handoff.
    private let lock = NSLock()
    private var state: State = .pending
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    func resolve(_ value: Value?) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return
        }
        state = .done(value)
        let waiting = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in waiting {
            waiter.resume(returning: value)
        }
    }

    var result: Value? {
        get async {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if case .done(let value) = state {
                        lock.unlock()
                        continuation.resume(returning: value)
                    } else if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else {
                        waiters[waiterID] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancel(waiterID: waiterID)
            }
        }
    }

    private func cancel(waiterID: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(returning: nil)
    }
}

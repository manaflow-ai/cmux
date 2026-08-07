public import Foundation

/// Owns sudo request discovery and user decision transitions.
public actor SudoBroker {
    /// Additional time after the CLI approval deadline before execution is killed.
    public static let executionGraceSeconds: Double = 90

    private let store: SudoSpoolStore
    private let dependencies: SudoBrokerDependencies
    private let messages: SudoFailureMessages
    private let eventStream: AsyncStream<SudoBrokerEvent>
    private let eventContinuation: AsyncStream<SudoBrokerEvent>.Continuation
    private var records: [String: SudoPendingRequest] = [:]
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var runnerMonitorTasks: [String: Task<Void, Never>] = [:]
    private var isWatching = false

    /// Creates the production broker hosted by one cmux app bundle.
    ///
    /// - Parameters:
    ///   - paths: The bundle-scoped private spool.
    ///   - runnerExecutableURL: The bundled `cmux` CLI used for independent execution.
    ///   - messages: Localized terminal diagnostics persisted with failures.
    ///   - pamConfiguration: The sudo PAM policy reader.
    public init(
        paths: SudoBrokerPaths,
        runnerExecutableURL: URL,
        messages: SudoFailureMessages,
        pamConfiguration: SudoPAMConfiguration = SudoPAMConfiguration()
    ) {
        let inspector = SystemSudoProcessInspector()
        let signaler = SystemSudoProcessSignaler()
        self.init(
            paths: paths,
            dependencies: SudoBrokerDependencies(
                clock: SystemSudoBrokerClock(),
                pam: pamConfiguration,
                runner: SudoRunnerLauncher(
                    executableURL: runnerExecutableURL,
                    inspector: inspector
                ),
                recovery: SudoExecutionRecovery(
                    inspector: inspector,
                    signaler: signaler
                ),
                watcher: SudoSpoolWatcher()
            ),
            messages: messages
        )
    }

    init(
        paths: SudoBrokerPaths,
        dependencies: SudoBrokerDependencies,
        messages: SudoFailureMessages,
        fileManager: FileManager = .default
    ) {
        store = SudoSpoolStore(paths: paths, fileManager: fileManager)
        self.dependencies = dependencies
        self.messages = messages
        let pair = AsyncStream.makeStream(
            of: SudoBrokerEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    /// Returns the lifecycle stream consumed by the approval presentation.
    ///
    /// - Returns: A bounded stream of authoritative request lifecycle events.
    public func events() -> AsyncStream<SudoBrokerEvent> {
        eventStream
    }

    /// Creates the private spool, reconciles durable state, and begins watching.
    ///
    /// - Returns: Newly discovered request snapshots.
    /// - Throws: A spool or watcher error when safe observation cannot start.
    public func start() async throws -> [SudoPendingRequest] {
        try store.ensureDirectories()
        if !isWatching, let watcher = dependencies.watcher {
            try await watcher.start(paths: store.paths) { [weak self] in
                Task {
                    try? await self?.refresh()
                }
            }
            isWatching = true
        }
        return try await refresh()
    }

    /// Reconciles filesystem state with the broker's in-memory presentation set.
    ///
    /// - Returns: Request snapshots discovered by this refresh.
    /// - Throws: A spool error when reconciliation cannot settle durable state.
    @discardableResult
    public func refresh() async throws -> [SudoPendingRequest] {
        let now = await dependencies.clock.now()
        try await recoverCleanupFailures(at: now)
        settleCompletedRecords()

        for (id, record) in records {
            guard let phase = store.state(id: id)?.phase,
                  phase != record.phase else {
                continue
            }
            records[id] = SudoPendingRequest(
                request: record.request,
                script: record.script,
                phase: phase
            )
            eventContinuation.yield(.phaseChanged(id: id, phase: phase))
        }

        let snapshots = store.pendingRequests()
        var discovered: [SudoPendingRequest] = []
        for snapshot in snapshots where records[snapshot.request.id] == nil {
            let id = snapshot.request.id
            let phase = store.state(id: id)?.phase ?? snapshot.phase
            if phase == .approved || phase == .executing {
                guard let state = store.state(id: id) else {
                    try settleInterrupted(id: id, at: now)
                    continue
                }
                let recovery = await dependencies.recovery.recover(
                    state: state,
                    approvedDirectory: store.paths.approved
                )
                if recovery == .recovered {
                    try settleInterrupted(id: id, at: now)
                    continue
                }
                if recovery == .cleanupIncomplete {
                    try settleCleanupFailure(id: id, at: now)
                    continue
                }
                let executing = SudoPendingRequest(
                    request: snapshot.request,
                    script: snapshot.script,
                    phase: phase
                )
                records[id] = executing
                discovered.append(executing)
                eventContinuation.yield(.discovered(executing))
                continue
            }

            if snapshot.request.approvalDeadline <= now {
                try settle(
                    SudoResult(
                        id: id,
                        status: .failed,
                        errorCode: .approvalTimedOut,
                        note: messages.approvalTimedOut
                    ),
                    auditStatus: "expired",
                    at: now
                )
                continue
            }

            let pending = SudoPendingRequest(
                request: snapshot.request,
                script: snapshot.script,
                phase: .pendingApproval
            )
            records[id] = pending
            discovered.append(pending)
            eventContinuation.yield(.discovered(pending))
            scheduleExpiry(for: pending)
        }
        return discovered
    }

    /// Returns the currently presented request snapshots.
    ///
    /// - Returns: Non-terminal snapshots sorted by request identifier.
    public func pendingRequests() -> [SudoPendingRequest] {
        records.values.sorted { $0.request.id < $1.request.id }
    }

    /// Approves the exact captured script after the PAM preflight succeeds.
    ///
    /// - Parameter id: The request identifier selected by the user.
    public func approve(id: String) async {
        guard let pending = records[id], pending.phase == .pendingApproval else { return }
        let now = await dependencies.clock.now()
        guard dependencies.pam.touchIDIsEnabled() else {
            try? settle(
                SudoResult(
                    id: id,
                    status: .failed,
                    errorCode: .pamTidUnavailable,
                    note: messages.pamTidUnavailable
                ),
                auditStatus: "failed pam-preflight",
                at: now
            )
            return
        }

        do {
            switch try store.transitionToApproved(
                pending: pending,
                now: now,
                executionGraceSeconds: Self.executionGraceSeconds
            ) {
            case .expired:
                try settle(
                    SudoResult(
                        id: id,
                        status: .failed,
                        errorCode: .approvalTimedOut,
                        note: messages.approvalTimedOut
                    ),
                    auditStatus: "expired approval-race",
                    at: now
                )
            case .unavailable:
                try await refresh()
            case .approved:
                cancelExpiry(id: id)
                records[id] = SudoPendingRequest(
                    request: pending.request,
                    script: pending.script,
                    phase: .approved
                )
                eventContinuation.yield(.phaseChanged(id: id, phase: .approved))
                do {
                    let runner = try await dependencies.runner.launch(requestID: id)
                    monitor(runner: runner, requestID: id)
                } catch {
                    try settle(
                        SudoResult(
                            id: id,
                            status: .failed,
                            errorCode: .runnerLaunchFailed,
                            note: messages.runnerLaunchFailed
                        ),
                        auditStatus: "failed runner-launch",
                        at: now
                    )
                }
            }
        } catch {
            try? settle(
                SudoResult(
                    id: id,
                    status: .failed,
                    errorCode: .stagingFailed,
                    note: messages.stagingFailed
                ),
                auditStatus: "failed staging",
                at: now
            )
        }
    }

    /// Denies a request without executing its script.
    ///
    /// - Parameter id: The request identifier selected by the user.
    public func deny(id: String) async {
        guard records[id]?.phase == .pendingApproval else { return }
        let now = await dependencies.clock.now()
        try? settle(
            SudoResult(id: id, status: .denied),
            auditStatus: "denied",
            at: now
        )
    }

    /// Stops observation and pending expiry work without abandoning live runners.
    public func stop() async {
        for task in expiryTasks.values {
            task.cancel()
        }
        expiryTasks.removeAll()
        if isWatching {
            await dependencies.watcher?.stop()
            isWatching = false
        }
    }

    private func scheduleExpiry(for pending: SudoPendingRequest) {
        let id = pending.request.id
        cancelExpiry(id: id)
        let clock = dependencies.clock
        let deadline = pending.request.approvalDeadline
        expiryTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                await self?.expirePending(id: id)
            } catch {
                return
            }
        }
    }

    private func expirePending(id: String) async {
        guard records[id]?.phase == .pendingApproval else { return }
        let now = await dependencies.clock.now()
        try? settle(
            SudoResult(
                id: id,
                status: .failed,
                errorCode: .approvalTimedOut,
                note: messages.approvalTimedOut
            ),
            auditStatus: "expired deadline",
            at: now
        )
    }

    private func settleInterrupted(id: String, at date: Date) throws {
        try settle(
            SudoResult(
                id: id,
                status: .failed,
                errorCode: .executionInterrupted,
                note: messages.executionInterrupted
            ),
            auditStatus: "failed recovery",
            at: date
        )
    }

    private func settleCleanupFailure(id: String, at date: Date) throws {
        try settle(
            SudoResult(
                id: id,
                status: .failed,
                errorCode: .processCleanupFailed,
                note: messages.cleanupFailed
            ),
            auditStatus: "failed recovery-cleanup",
            at: date
        )
    }

    private func recoverCleanupFailures(at date: Date) async throws {
        for state in store.cleanupFailureStates() {
            let recovery = await dependencies.recovery.recover(
                state: state,
                approvedDirectory: store.paths.approved
            )
            guard recovery == .recovered else { continue }
            try store.archiveRecoveredCleanup(id: state.id)
            store.appendAudit(
                "\(date.ISO8601Format()) \(state.id) recovered cleanup"
            )
        }
    }

    private func settleCompletedRecords() {
        for id in Array(records.keys) {
            guard let result = store.result(id: id) else { continue }
            cancelExpiry(id: id)
            cancelRunnerMonitor(id: id)
            records.removeValue(forKey: id)
            eventContinuation.yield(.settled(result))
        }
    }

    private func monitor(runner: SudoLaunchedRunner, requestID: String) {
        cancelRunnerMonitor(id: requestID)
        runnerMonitorTasks[requestID] = Task { [weak self] in
            for await _ in runner.termination {
                guard !Task.isCancelled else { return }
                await self?.runnerTerminated(requestID: requestID)
                return
            }
        }
    }

    private func runnerTerminated(requestID: String) async {
        runnerMonitorTasks.removeValue(forKey: requestID)
        if store.result(id: requestID) != nil {
            settleCompletedRecords()
            return
        }

        let now = await dependencies.clock.now()
        guard let state = store.state(id: requestID) else {
            try? settleInterrupted(id: requestID, at: now)
            return
        }
        let recovery = await dependencies.recovery.recover(
            state: state,
            approvedDirectory: store.paths.approved
        )
        guard store.result(id: requestID) == nil else {
            settleCompletedRecords()
            return
        }
        switch recovery {
        case .runnerActive:
            return
        case .recovered:
            try? settleInterrupted(id: requestID, at: now)
        case .cleanupIncomplete:
            try? settleCleanupFailure(id: requestID, at: now)
        }
    }

    private func settle(
        _ result: SudoResult,
        auditStatus: String,
        at date: Date
    ) throws {
        _ = try store.settle(result)
        cancelExpiry(id: result.id)
        cancelRunnerMonitor(id: result.id)
        records.removeValue(forKey: result.id)
        store.appendAudit(
            "\(date.ISO8601Format()) \(result.id) \(auditStatus)"
        )
        eventContinuation.yield(.settled(store.result(id: result.id) ?? result))
    }

    private func cancelExpiry(id: String) {
        expiryTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelRunnerMonitor(id: String) {
        runnerMonitorTasks.removeValue(forKey: id)?.cancel()
    }
}

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
    private var recoveredRunnerTasks: [String: Task<Void, Never>] = [:]
    private var cleanupRetryTasks: [String: Task<Void, Never>] = [:]
    private var requesterExitTasks: [String: Task<Void, Never>] = [:]
    private var requesterExitGenerations: [String: UInt64] = [:]
    private var nextRequesterExitGeneration: UInt64 = 0
    private var cleanupRetryNotBefore: [String: Date] = [:]
    private var cleanupRecoveryAttempts: [String: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var isWatching = false
    private var shouldWatch = false
    private var watcherGeneration: UInt64 = 0

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
                watcher: SudoSpoolWatcher(),
                requesterInspector: inspector,
                requesterExitObserver: SudoProcessExitObserver(inspector: inspector)
            ),
            messages: messages
        )
    }

    init(
        paths: SudoBrokerPaths,
        dependencies: SudoBrokerDependencies,
        messages: SudoFailureMessages,
        fileManager: FileManager = .default,
        resourcePolicy: SudoResourcePolicy = .standard
    ) {
        store = SudoSpoolStore(
            paths: paths,
            resourcePolicy: resourcePolicy,
            fileManager: fileManager
        )
        self.dependencies = dependencies
        self.messages = messages
        let pair = AsyncStream.makeStream(
            of: SudoBrokerEvent.self,
            bufferingPolicy: .bufferingNewest(1)
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
    /// - Returns: Every active request snapshot after startup reconciliation.
    /// - Throws: A spool or watcher error when safe observation cannot start.
    public func start() async throws -> [SudoPendingRequest] {
        // A second start supersedes callbacks registered by the prior watch
        // generation. Cancel them before refreshing so a stale exit event cannot
        // consume the newly armed observer for the same request.
        let activeRequesterExitTasks = Array(requesterExitTasks.values)
        for task in activeRequesterExitTasks {
            task.cancel()
        }
        requesterExitTasks.removeAll()
        requesterExitGenerations.removeAll()
        watcherGeneration &+= 1
        let generation = watcherGeneration
        shouldWatch = true
        try store.ensureDirectories()
        if !isWatching, let watcher = dependencies.watcher {
            try await watcher.start(paths: store.paths) { [weak self] in
                Task { await self?.requestRefresh() }
            }
            guard generation == watcherGeneration,
                  shouldWatch,
                  !Task.isCancelled else {
                if !shouldWatch {
                    await watcher.stop()
                }
                throw CancellationError()
            }
            isWatching = true
        }
        _ = try await refresh()
        return pendingRequests()
    }

    /// Reconciles filesystem state with the broker's in-memory presentation set.
    ///
    /// - Returns: Request snapshots discovered by this refresh.
    /// - Throws: A spool error when reconciliation cannot settle durable state.
    @discardableResult
    public func refresh() async throws -> [SudoPendingRequest] {
        try Task.checkCancellation()
        let now = await dependencies.clock.now()
        settleCompletedRecords(publishChanges: false)

        for id in Array(records.keys) {
            guard let record = records[id] else { continue }
            guard let phase = store.state(id: id)?.phase,
                  phase != record.phase else {
                continue
            }
            let updatedRecord = SudoPendingRequest(
                request: record.request,
                script: record.script,
                phase: phase
            )
            records[id] = updatedRecord
            if phase == .pendingApproval {
                if requesterExitTasks[id] == nil,
                   let currentRecord = records[id] {
                    scheduleRequesterExit(for: currentRecord)
                }
            } else {
                cancelRequesterExit(id: id)
            }
        }

        let snapshots = store.pendingRequests()
        let cleanupFailureStates = store.cleanupFailureStates()
        var phasesByID: [String: SudoRequestPhase] = [:]
        var recoveryStatesByID = Dictionary(
            uniqueKeysWithValues: cleanupFailureStates.map { ($0.id, $0) }
        )
        for snapshot in snapshots {
            let id = snapshot.request.id
            let state = store.state(id: id)
            let phase = state?.phase ?? snapshot.phase
            phasesByID[id] = phase
            if phase == .approved || phase == .executing,
               records[id] == nil,
               let state {
                recoveryStatesByID[id] = state
            }
        }
        let recoveryStates = recoveryStatesByID.values
            .filter { state in
                guard let notBefore = cleanupRetryNotBefore[state.id] else { return true }
                return notBefore <= now
            }
            .sorted { $0.id < $1.id }
        let recoveries = recoveryStates.isEmpty
            ? [:]
            : await dependencies.recovery.recover(
                states: recoveryStates,
                approvedDirectory: store.paths.approved
            )
        try Task.checkCancellation()
        recoverCleanupFailures(
            cleanupFailureStates,
            recoveries: recoveries,
            at: now
        )
        for state in recoveryStates {
            switch recoveries[state.id] {
            case .cleanupIncomplete:
                let attempts = cleanupRecoveryAttempts[state.id, default: 0] + 1
                cleanupRecoveryAttempts[state.id] = attempts
                if attempts < store.resourcePolicy.maximumCleanupRecoveryAttempts {
                    scheduleCleanupRetry(
                        id: state.id,
                        notBefore: now.addingTimeInterval(5)
                    )
                } else {
                    cleanupRetryTasks.removeValue(forKey: state.id)?.cancel()
                    cleanupRetryNotBefore[state.id] = .distantFuture
                }
            case .recovered, .runnerActive, .none:
                cleanupRecoveryAttempts.removeValue(forKey: state.id)
                cancelCleanupRetry(id: state.id)
            }
        }

        var discovered: [SudoPendingRequest] = []
        for snapshot in snapshots {
            try Task.checkCancellation()
            let id = snapshot.request.id
            let wasKnown = records[id] != nil
            let phase = phasesByID[id] ?? snapshot.phase
            if phase == .approved || phase == .executing {
                guard !wasKnown else { continue }
                guard recoveryStatesByID[id] != nil else {
                    settleInterruptedIfPossible(id: id, at: now)
                    continue
                }
                guard let recovery = recoveries[id] else {
                    let executing = SudoPendingRequest(
                        request: snapshot.request,
                        script: snapshot.script,
                        phase: phase
                    )
                    records[id] = executing
                    discovered.append(executing)
                    continue
                }
                if recovery == .recovered {
                    settleInterruptedIfPossible(id: id, at: now)
                    continue
                }
                if recovery == .cleanupIncomplete {
                    settleCleanupFailureIfPossible(id: id, at: now)
                    continue
                }
                scheduleRecoveredRunnerReconciliation(
                    id: id,
                    deadline: store.manifest(id: id)?.deadline
                        ?? now.addingTimeInterval(Self.executionGraceSeconds)
                )
                let executing = SudoPendingRequest(
                    request: snapshot.request,
                    script: snapshot.script,
                    phase: phase
                )
                records[id] = executing
                discovered.append(executing)
                continue
            }

            if snapshot.request.approvalDeadline <= now {
                settleIfPossible(
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

            guard requesterIsAvailable(snapshot.request) else {
                settleIfPossible(
                    SudoResult(
                        id: id,
                        status: .failed,
                        errorCode: .requesterUnavailable,
                        note: messages.requesterUnavailable
                    ),
                    auditStatus: "failed requester-validation",
                    at: now
                )
                continue
            }

            if wasKnown {
                guard let existing = records[id],
                      existing.script == snapshot.script else {
                    settleIfPossible(
                        SudoResult(
                            id: id,
                            status: .failed,
                            errorCode: .stagingFailed,
                            note: messages.stagingFailed
                        ),
                        auditStatus: "failed snapshot-mutation",
                        at: now
                    )
                    continue
                }
                if expiryTasks[id] == nil, existing.phase == .pendingApproval {
                    scheduleExpiry(for: existing)
                }
                if existing.phase == .pendingApproval, requesterExitTasks[id] == nil {
                    scheduleRequesterExit(for: existing)
                }
                continue
            }

            let pending = SudoPendingRequest(
                request: snapshot.request,
                script: snapshot.script,
                phase: .pendingApproval
            )
            records[id] = pending
            if !wasKnown {
                discovered.append(pending)
            }
            if expiryTasks[id] == nil {
                scheduleExpiry(for: pending)
            }
            scheduleRequesterExit(for: pending)
        }
        publishSnapshot()
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
        guard requesterIsAvailable(pending.request) else {
            settleIfPossible(
                SudoResult(
                    id: id,
                    status: .failed,
                    errorCode: .requesterUnavailable,
                    note: messages.requesterUnavailable
                ),
                auditStatus: "failed requester-validation",
                at: now
            )
            return
        }
        guard dependencies.pam.touchIDIsEnabled() else {
            settleIfPossible(
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

        // Each launched runner owns a dedicated low-level reaper. Keep the
        // number of live runners bounded before moving this request out of the
        // pending spool so approval bursts cannot accumulate one thread per
        // ninety-second execution grace period.
        settleCompletedRecords()
        guard activeRunnerCount() < store.resourcePolicy.maximumActiveRunnerCount else {
            settleIfPossible(
                SudoResult(
                    id: id,
                    status: .failed,
                    errorCode: .runnerLaunchFailed,
                    note: messages.runnerLaunchFailed
                ),
                auditStatus: "failed active-runner-cap",
                at: now
            )
            return
        }

        let transition: SudoSpoolStore.ApprovalTransition
        do {
            transition = try store.transitionToApproved(
                pending: pending,
                now: now,
                executionGraceSeconds: Self.executionGraceSeconds
            )
        } catch {
            settleIfPossible(
                SudoResult(
                    id: id,
                    status: .failed,
                    errorCode: .stagingFailed,
                    note: messages.stagingFailed
                ),
                auditStatus: "failed staging",
                at: now
            )
            return
        }

        switch transition {
        case .expired:
            settleIfPossible(
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
            do {
                try await refresh()
            } catch {
                store.appendAudit(
                    "\(now.ISO8601Format()) \(id) failed approval-refresh"
                )
            }
        case .approved(let manifest):
            cancelExpiry(id: id)
            cancelRequesterExit(id: id)
            records[id] = SudoPendingRequest(
                request: pending.request,
                script: pending.script,
                phase: .approved
            )
            publishSnapshot()
            do {
                let runner = try await dependencies.runner.launch(
                    requestID: id,
                    reviewedScript: Data(pending.script.utf8),
                    manifest: manifest
                )
                monitor(runner: runner, requestID: id)
            } catch {
                settleIfPossible(
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
    }

    /// Denies a request without executing its script.
    ///
    /// - Parameter id: The request identifier selected by the user.
    public func deny(id: String) async {
        guard records[id]?.phase == .pendingApproval else { return }
        let now = await dependencies.clock.now()
        settleIfPossible(
            SudoResult(id: id, status: .denied),
            auditStatus: "denied",
            at: now
        )
    }

    /// Stops observation and pending expiry work without abandoning live runners.
    public func stop() async {
        watcherGeneration &+= 1
        shouldWatch = false
        isWatching = false
        let activeRefreshTask = refreshTask
        activeRefreshTask?.cancel()
        refreshRequested = false
        let activeExpiryTasks = Array(expiryTasks.values)
        for task in activeExpiryTasks {
            task.cancel()
        }
        expiryTasks.removeAll()
        let activeRecoveredRunnerTasks = Array(recoveredRunnerTasks.values)
        for task in activeRecoveredRunnerTasks {
            task.cancel()
        }
        recoveredRunnerTasks.removeAll()
        let activeCleanupRetryTasks = Array(cleanupRetryTasks.values)
        for task in activeCleanupRetryTasks {
            task.cancel()
        }
        cleanupRetryTasks.removeAll()
        cleanupRetryNotBefore.removeAll()
        cleanupRecoveryAttempts.removeAll()
        let activeRequesterExitTasks = Array(requesterExitTasks.values)
        for task in activeRequesterExitTasks {
            task.cancel()
        }
        requesterExitTasks.removeAll()
        requesterExitGenerations.removeAll()
        await dependencies.watcher?.stop()
        await activeRefreshTask?.value
        for task in activeExpiryTasks {
            await task.value
        }
        for task in activeRecoveredRunnerTasks {
            await task.value
        }
        for task in activeCleanupRetryTasks {
            await task.value
        }
        for task in activeRequesterExitTasks {
            await task.value
        }
        refreshTask = nil
    }

    private func requestRefresh() {
        guard isWatching else { return }
        refreshRequested = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.drainRefreshRequests()
        }
    }

    private func drainRefreshRequests() async {
        while isWatching, refreshRequested, !Task.isCancelled {
            refreshRequested = false
            _ = try? await refresh()
        }
        refreshTask = nil
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

    private func scheduleRequesterExit(for pending: SudoPendingRequest) {
        guard pending.phase == .pendingApproval,
              let identity = pending.request.requesterIdentity,
              let observer = dependencies.requesterExitObserver else {
            return
        }
        let id = pending.request.id
        let generation = watcherGeneration
        cancelRequesterExit(id: id)
        nextRequesterExitGeneration &+= 1
        let observationGeneration = nextRequesterExitGeneration
        requesterExitGenerations[id] = observationGeneration
        requesterExitTasks[id] = Task { [weak self] in
            for await _ in observer.events(for: identity) {
                guard !Task.isCancelled else { return }
                await self?.requesterExited(
                    id: id,
                    identity: identity,
                    generation: generation,
                    observationGeneration: observationGeneration
                )
                return
            }
        }
    }

    private func requesterExited(
        id: String,
        identity: SudoProcessIdentity,
        generation: UInt64,
        observationGeneration: UInt64
    ) async {
        guard requesterExitGenerations[id] == observationGeneration else {
            return
        }
        defer {
            if requesterExitGenerations[id] == observationGeneration {
                requesterExitTasks.removeValue(forKey: id)
                requesterExitGenerations.removeValue(forKey: id)
            }
        }
        guard shouldWatch,
              generation == watcherGeneration,
              let record = records[id],
              record.phase == .pendingApproval,
              record.request.requesterIdentity == identity else {
            return
        }
        let now = await dependencies.clock.now()
        guard !Task.isCancelled,
              shouldWatch,
              generation == watcherGeneration,
              requesterExitGenerations[id] == observationGeneration,
              let currentRecord = records[id],
              currentRecord.phase == .pendingApproval,
              currentRecord.request.requesterIdentity == identity else {
            return
        }
        settleIfPossible(
            SudoResult(
                id: id,
                status: .failed,
                errorCode: .requesterUnavailable,
                note: messages.requesterUnavailable
            ),
            auditStatus: "failed requester-exit",
            at: now
        )
    }

    private func expirePending(id: String) async {
        guard records[id]?.phase == .pendingApproval else { return }
        let now = await dependencies.clock.now()
        settleIfPossible(
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

    private func settleInterruptedIfPossible(id: String, at date: Date) {
        do {
            try settleInterrupted(id: id, at: date)
        } catch {
            store.appendAudit(
                "\(date.ISO8601Format()) \(id) failed recovery-settle"
            )
        }
    }

    private func settleCleanupFailureIfPossible(id: String, at date: Date) {
        do {
            try settleCleanupFailure(id: id, at: date)
        } catch {
            store.appendAudit(
                "\(date.ISO8601Format()) \(id) failed recovery-cleanup-settle"
            )
        }
    }

    private func settleIfPossible(
        _ result: SudoResult,
        auditStatus: String,
        at date: Date
    ) {
        do {
            try settle(result, auditStatus: auditStatus, at: date)
        } catch {
            store.appendAudit(
                "\(date.ISO8601Format()) \(result.id) failed \(auditStatus)-settle"
            )
            guard result.errorCode == .stagingFailed || result.errorCode == .runnerLaunchFailed,
                  (try? store.requeueAfterSettlementFailure(id: result.id, now: date)) == true,
                  let record = records[result.id] else {
                return
            }
            cancelRunnerMonitor(id: result.id)
            let pending = SudoPendingRequest(
                request: record.request,
                script: record.script,
                phase: .pendingApproval
            )
            records[result.id] = pending
            scheduleExpiry(for: pending)
            scheduleRequesterExit(for: pending)
            publishSnapshot()
        }
    }

    private func requesterIsAvailable(_ request: SudoRequest) -> Bool {
        guard let identity = request.requesterIdentity else { return false }
        return dependencies.requesterInspector.isRunning(identity)
    }

    private func recoverCleanupFailures(
        _ states: [SudoRequestState],
        recoveries: [String: SudoExecutionRecoveryDisposition],
        at date: Date
    ) {
        for state in states where recoveries[state.id] == .recovered {
            do {
                try store.archiveRecoveredCleanup(id: state.id)
                store.appendAudit(
                    "\(date.ISO8601Format()) \(state.id) recovered cleanup"
                )
            } catch {
                store.appendAudit(
                    "\(date.ISO8601Format()) \(state.id) failed cleanup-archive"
                )
            }
        }
    }

    private func settleCompletedRecords(publishChanges: Bool = true) {
        var removedRecord = false
        for id in Array(records.keys) {
            guard store.authoritativeResult(id: id) != nil else { continue }
            cancelExpiry(id: id)
            cancelRequesterExit(id: id)
            cancelRunnerMonitor(id: id)
            cancelRecoveredRunnerReconciliation(id: id)
            records.removeValue(forKey: id)
            removedRecord = true
        }
        if removedRecord, publishChanges { publishSnapshot() }
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
        cancelRecoveredRunnerReconciliation(id: requestID)
        runnerMonitorTasks.removeValue(forKey: requestID)
        if store.authoritativeResult(id: requestID) != nil {
            settleCompletedRecords()
            return
        }

        let now = await dependencies.clock.now()
        guard let state = store.state(id: requestID) else {
            settleInterruptedIfPossible(id: requestID, at: now)
            return
        }
        let recoveries = await dependencies.recovery.recover(
            states: [state],
            approvedDirectory: store.paths.approved
        )
        guard store.authoritativeResult(id: requestID) == nil else {
            settleCompletedRecords()
            return
        }
        switch recoveries[state.id] ?? .cleanupIncomplete {
        case .runnerActive:
            return
        case .recovered:
            settleInterruptedIfPossible(id: requestID, at: now)
        case .cleanupIncomplete:
            settleCleanupFailureIfPossible(id: requestID, at: now)
        }
    }

    private func settle(
        _ result: SudoResult,
        auditStatus: String,
        at date: Date
    ) throws {
        _ = try store.settle(result)
        cancelExpiry(id: result.id)
        cancelRequesterExit(id: result.id)
        cancelRunnerMonitor(id: result.id)
        cancelRecoveredRunnerReconciliation(id: result.id)
        cancelCleanupRetry(id: result.id)
        cleanupRecoveryAttempts.removeValue(forKey: result.id)
        records.removeValue(forKey: result.id)
        store.appendAudit(
            "\(date.ISO8601Format()) \(result.id) \(auditStatus)"
        )
        publishSnapshot()
    }

    private func cancelExpiry(id: String) {
        expiryTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelRequesterExit(id: String) {
        requesterExitTasks.removeValue(forKey: id)?.cancel()
        requesterExitGenerations.removeValue(forKey: id)
    }

    private func cancelRunnerMonitor(id: String) {
        runnerMonitorTasks.removeValue(forKey: id)?.cancel()
    }

    private func activeRunnerCount() -> Int {
        var activeIDs = Set(
            records.values.compactMap { record in
                switch record.phase {
                case .approved, .executing:
                    return record.request.id
                case .pendingApproval:
                    return nil
                }
            }
        )
        activeIDs.formUnion(store.cleanupFailureStates().map(\.id))
        return activeIDs.count
    }

    private func scheduleRecoveredRunnerReconciliation(id: String, deadline: Date) {
        cancelRecoveredRunnerReconciliation(id: id)
        let clock = dependencies.clock
        recoveredRunnerTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                await self?.reconcileRecoveredRunner(id: id)
            } catch {
                return
            }
        }
    }

    private func reconcileRecoveredRunner(id: String) async {
        recoveredRunnerTasks.removeValue(forKey: id)
        guard let state = store.state(id: id) else {
            settleInterruptedIfPossible(id: id, at: await dependencies.clock.now())
            return
        }
        let recoveries = await dependencies.recovery.recover(
            states: [state],
            approvedDirectory: store.paths.approved
        )
        let now = await dependencies.clock.now()
        switch recoveries[id] ?? .cleanupIncomplete {
        case .recovered:
            settleInterruptedIfPossible(id: id, at: now)
        case .cleanupIncomplete:
            settleCleanupFailureIfPossible(id: id, at: now)
        case .runnerActive:
            scheduleRecoveredRunnerReconciliation(
                id: id,
                deadline: now.addingTimeInterval(5)
            )
        }
    }

    private func cancelRecoveredRunnerReconciliation(id: String) {
        recoveredRunnerTasks.removeValue(forKey: id)?.cancel()
    }

    private func scheduleCleanupRetry(id: String, notBefore: Date) {
        cleanupRetryNotBefore[id] = notBefore
        cleanupRetryTasks.removeValue(forKey: id)?.cancel()
        let clock = dependencies.clock
        cleanupRetryTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(until: notBefore)
                try Task.checkCancellation()
                await self?.requestRefresh()
            } catch {
                return
            }
        }
    }

    private func cancelCleanupRetry(id: String) {
        cleanupRetryTasks.removeValue(forKey: id)?.cancel()
        cleanupRetryNotBefore.removeValue(forKey: id)
    }

    private func publishSnapshot() {
        eventContinuation.yield(.snapshot(pendingRequests()))
    }
}

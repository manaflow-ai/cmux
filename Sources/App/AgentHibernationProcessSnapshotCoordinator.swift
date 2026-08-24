import Darwin
import Foundation

/// Coalesces authoritative process-table refreshes across hibernating panels.
actor AgentHibernationProcessSnapshotCoordinator {
    typealias SnapshotCapture = @Sendable () async -> CmuxTopProcessSnapshot
    typealias CaptureScheduler = @Sendable () async -> Void
    typealias ProcessArgumentsProvider =
        @Sendable (Int) -> CmuxTopProcessArguments?
    typealias ProcessIdentityProvider =
        @Sendable (pid_t) -> AgentPIDProcessIdentity?
    typealias ProcessGroupProvider = @Sendable (pid_t) -> pid_t

    private let captureSnapshot: SnapshotCapture
    private let beforeCapture: CaptureScheduler
    private let processArgumentsProvider: ProcessArgumentsProvider
    private let processIdentityProvider: ProcessIdentityProvider
    private let processGroupProvider: ProcessGroupProvider
    private var activeSnapshotWaiters:
        [UUID: CheckedContinuation<CmuxTopProcessSnapshot?, Never>] = [:]
    private var queuedSnapshotWaiters:
        [UUID: CheckedContinuation<CmuxTopProcessSnapshot?, Never>] = [:]
    private var captureTask: Task<Void, Never>?
    private var captureHasStarted = false

    var queuedSnapshotWaiterCount: Int {
        queuedSnapshotWaiters.count
    }

    init(
        beforeCapture: @escaping CaptureScheduler = {
            await Task.yield()
        },
        captureSnapshot: @escaping SnapshotCapture = {
            await AgentHibernationProcessSnapshotCoordinator.captureFreshSnapshot()
        },
        processArgumentsProvider: @escaping ProcessArgumentsProvider = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        },
        processIdentityProvider: @escaping ProcessIdentityProvider = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processGroupProvider: @escaping ProcessGroupProvider = {
            getpgid($0)
        }
    ) {
        self.beforeCapture = beforeCapture
        self.captureSnapshot = captureSnapshot
        self.processArgumentsProvider = processArgumentsProvider
        self.processIdentityProvider = processIdentityProvider
        self.processGroupProvider = processGroupProvider
    }

    /// Returns one fresh snapshot shared by requests already queued for this capture epoch.
    func nextSnapshot() async -> CmuxTopProcessSnapshot? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                queuedSnapshotWaiters[waiterID] = continuation
                scheduleCaptureIfNeeded()
            }
        } onCancel: {
            Task {
                await self.cancelSnapshotWaiter(waiterID)
            }
        }
    }

    func refreshedExitEpoch(
        processGroupLeaders: [pid_t: AgentPIDProcessIdentity],
        processScopeKey: AgentHibernationPanelKey?,
        ttyDevice: Int64?,
        excluding exitedIdentities: Set<AgentPIDProcessIdentity>
    ) async -> AgentHibernationProcessExitEpoch? {
        guard let snapshot = await nextSnapshot() else { return nil }
        return Self.exitEpoch(
            in: snapshot,
            processGroupLeaders: processGroupLeaders,
            processScopeKey: processScopeKey,
            ttyDevice: ttyDevice,
            processArgumentsProvider: processArgumentsProvider,
            processIdentityProvider: processIdentityProvider,
            processGroupProvider: processGroupProvider,
            excluding: exitedIdentities
        )
    }

    private func scheduleCaptureIfNeeded() {
        guard captureTask == nil, !queuedSnapshotWaiters.isEmpty else { return }
        captureTask = Task { [weak self, beforeCapture] in
            // Let all exit events already queued on the actor join one fresh capture.
            await beforeCapture()
            guard !Task.isCancelled else {
                await self?.finishCancelledCapture()
                return
            }
            await self?.runCapture()
        }
    }

    private func runCapture() async {
        captureHasStarted = true
        activeSnapshotWaiters = queuedSnapshotWaiters
        queuedSnapshotWaiters.removeAll(keepingCapacity: true)
        let snapshot = await captureSnapshot()
        let waiters = Array(activeSnapshotWaiters.values)
        activeSnapshotWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
        captureHasStarted = false
        captureTask = nil
        scheduleCaptureIfNeeded()
    }

    private func cancelSnapshotWaiter(_ waiterID: UUID) {
        let waiter = activeSnapshotWaiters.removeValue(forKey: waiterID) ??
            queuedSnapshotWaiters.removeValue(forKey: waiterID)
        waiter?.resume(returning: nil)
        let captureHasNoWaiters = captureHasStarted
            ? activeSnapshotWaiters.isEmpty
            : queuedSnapshotWaiters.isEmpty
        if captureHasNoWaiters {
            captureTask?.cancel()
        }
    }

    private func finishCancelledCapture() {
        captureHasStarted = false
        captureTask = nil
        scheduleCaptureIfNeeded()
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func captureFreshSnapshot() async -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot.capture(
            includeProcessDetails: false,
            includeCMUXScope: false
        )
    }

    private nonisolated static func exitEpoch(
        in snapshot: CmuxTopProcessSnapshot,
        processGroupLeaders: [pid_t: AgentPIDProcessIdentity],
        processScopeKey: AgentHibernationPanelKey?,
        ttyDevice: Int64?,
        processArgumentsProvider: ProcessArgumentsProvider,
        processIdentityProvider: ProcessIdentityProvider,
        processGroupProvider: ProcessGroupProvider,
        excluding exitedIdentities: Set<AgentPIDProcessIdentity>
    ) -> AgentHibernationProcessExitEpoch? {
        var authorizedLeaders: [pid_t: AgentPIDProcessIdentity] = [:]
        for (processGroupID, leaderIdentity) in processGroupLeaders {
            let memberIDs = snapshot.pids(forProcessGroupID: Int(processGroupID))
            guard !memberIDs.isEmpty else { continue }
            if snapshot.processesByPID[Int(processGroupID)] != nil,
               processIdentityProvider(processGroupID) != leaderIdentity {
                continue
            }
            authorizedLeaders[processGroupID] = leaderIdentity
        }

        var observedProcessIDs: Set<Int> = []
        for processGroupID in authorizedLeaders.keys {
            observedProcessIDs.formUnion(
                snapshot.pids(forProcessGroupID: Int(processGroupID))
            )
        }
        if processScopeKey != nil {
            guard let ttyDevice else { return nil }
            observedProcessIDs.formUnion(
                snapshot.pids(forTTYDevice: ttyDevice)
            )
        }
        guard observedProcessIDs.count <=
                AgentHibernationController.maximumScopedProcessTerminationCount else {
            return nil
        }
        if let processScopeKey {
            guard observedProcessIDs.allSatisfy({ processID in
                processArgumentsProvider(processID)?.matchesCMUXScope(
                    workspaceId: processScopeKey.workspaceId,
                    surfaceId: processScopeKey.panelId
                ) == true
            }) else {
                return nil
            }
        }

        var nextTerminations: [AgentPIDProcessIdentity:
            AgentHibernationController.ScopedProcessTermination] = [:]
        var liveAuthorizedLeaders: [pid_t: AgentPIDProcessIdentity] = [:]
        var signalableProcessIdentities: Set<AgentPIDProcessIdentity> = []
        for processID in observedProcessIDs {
            guard processID > 0,
                  let process = snapshot.processesByPID[processID],
                  let rawProcessGroupID = process.processGroupID,
                  rawProcessGroupID > 1 else {
                return nil
            }
            let processGroupID = pid_t(rawProcessGroupID)
            guard let identity = processIdentityProvider(pid_t(processID)) else {
                return nil
            }
            guard !exitedIdentities.contains(identity) else { continue }
            guard processGroupProvider(pid_t(processID)) == processGroupID else {
                return nil
            }
            nextTerminations[identity] = .init(
                processID: processID,
                processIdentity: identity,
                processGroupID: processGroupID,
                ttyDevice: process.ttyDevice
            )
            if let leaderIdentity = authorizedLeaders[processGroupID] {
                liveAuthorizedLeaders[processGroupID] = leaderIdentity
                signalableProcessIdentities.insert(identity)
            }
        }

        return AgentHibernationProcessExitEpoch(
            terminations: nextTerminations.values.sorted {
                $0.processID > $1.processID
            },
            processGroupLeaders: liveAuthorizedLeaders,
            signalableProcessIdentities: signalableProcessIdentities
        )
    }
}

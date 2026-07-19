import Darwin
import Foundation
import os

final class AgentHibernationRestoreMonitorScheduler: @unchecked Sendable {
    static let shared = AgentHibernationRestoreMonitorScheduler(
        maximumConcurrentMonitors: 8
    )

    private struct State {
        var activeCount = 0
        var waiterOrder: [UUID] = []
        var waiterHead = 0
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

        mutating func appendWaiter(
            id: UUID,
            continuation: CheckedContinuation<Bool, Never>
        ) {
            waiterOrder.append(id)
            waiters[id] = continuation
        }

        mutating func removeWaiter(
            id: UUID
        ) -> CheckedContinuation<Bool, Never>? {
            let continuation = waiters.removeValue(forKey: id)
            if waiters.isEmpty {
                waiterOrder.removeAll(keepingCapacity: false)
                waiterHead = 0
            }
            return continuation
        }

        mutating func popWaiter() -> CheckedContinuation<Bool, Never>? {
            while waiterHead < waiterOrder.count {
                let id = waiterOrder[waiterHead]
                waiterHead += 1
                if let continuation = waiters.removeValue(forKey: id) {
                    compactWaiterOrderIfNeeded()
                    return continuation
                }
            }
            waiterOrder.removeAll(keepingCapacity: false)
            waiterHead = 0
            return nil
        }

        private mutating func compactWaiterOrderIfNeeded() {
            guard waiterHead >= 64,
                  waiterHead >= waiterOrder.count - waiterHead else {
                return
            }
            waiterOrder.removeFirst(waiterHead)
            waiterHead = 0
        }
    }

    private let maximumConcurrentMonitors: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maximumConcurrentMonitors: Int) {
        self.maximumConcurrentMonitors = max(1, maximumConcurrentMonitors)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Bool? in
                    guard !Task.isCancelled else { return false }
                    if state.activeCount < maximumConcurrentMonitors {
                        state.activeCount += 1
                        return true
                    }
                    state.appendWaiter(id: id, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let continuation = self.state.withLock { state in
                state.removeWaiter(id: id)
            }
            continuation?.resume(returning: false)
        }
    }

    func release() {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            precondition(state.activeCount > 0)
            state.activeCount -= 1
            guard let continuation = state.popWaiter() else { return nil }
            state.activeCount += 1
            return continuation
        }
        continuation?.resume(returning: true)
    }
}

actor AgentHibernationRestoreDispatchWait {
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [any DispatchSourceProtocol] = []
    private var didFinish = false

    func wait(
        for sources: [any DispatchSourceProtocol],
        onArmed: @Sendable () -> Void = {}
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if didFinish {
                    for source in sources {
                        source.cancel()
                        source.activate()
                    }
                    onArmed()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                self.sources = sources
                for source in sources { source.activate() }
                onArmed()
            }
        } onCancel: {
            Task { await self.finish() }
        }
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        let continuation = continuation
        let sources = sources
        self.continuation = nil
        self.sources = []
        for source in sources { source.cancel() }
        continuation?.resume()
    }
}

extension AgentHibernationTranscriptGuard {
    private static let restoreMonitorEventQueue = DispatchQueue(
        label: "com.cmuxterm.agent-hibernation-transcript-restore-events",
        qos: .utility
    )

    enum PostTeardownSnapshotDisposal: Sendable {
        /// Normal hibernation monitor: delete only after restore or a stable
        /// byte proof that the live transcript contains the snapshot.
        case deleteWhenSafe
        /// Forfeit monitor: on completion, move an uncommitted snapshot to the
        /// session's retained recovery slot instead of leaving UUID copies.
        case retainForRecovery(sessionId: String?)
    }

    private static func guardedProcessIsAlive(
        _ expectedIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        if let currentIdentity = AgentPIDProcessIdentity(pid: expectedIdentity.pid) {
            return currentIdentity == expectedIdentity
        }
        if kill(expectedIdentity.pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func waitForGuardedProcessExitOrBackstop(
        processIdentities: Set<AgentPIDProcessIdentity>,
        hasUnwatchedProcesses: Bool,
        backstopSeconds: Int
    ) async -> Bool {
        let liveProcessIdentities = processIdentities.filter(guardedProcessIsAlive)
        guard !liveProcessIdentities.isEmpty || hasUnwatchedProcesses else { return true }
        let waiter = AgentHibernationRestoreDispatchWait()
        var sources: [any DispatchSourceProtocol] = liveProcessIdentities.map { identity in
            let source = DispatchSource.makeProcessSource(
                identifier: identity.pid,
                eventMask: .exit,
                queue: restoreMonitorEventQueue
            )
            source.setEventHandler {
                if !hasUnwatchedProcesses,
                   !liveProcessIdentities.contains(where: guardedProcessIsAlive) {
                    Task { await waiter.finish() }
                }
            }
            return source
        }
        let timer = DispatchSource.makeTimerSource(queue: restoreMonitorEventQueue)
        timer.schedule(
            deadline: .now() + .seconds(max(0, backstopSeconds)),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { Task { await waiter.finish() } }
        sources.append(timer)
        restoreMonitorEventQueue.async {
            if !hasUnwatchedProcesses,
               !liveProcessIdentities.contains(where: guardedProcessIsAlive) {
                Task { await waiter.finish() }
            }
        }
        await waiter.wait(for: sources)
        return !hasUnwatchedProcesses
            && !processIdentities.contains(where: guardedProcessIsAlive)
    }

    private static func waitForTranscriptMutationOrBackstop(
        transcriptPath: String,
        delayNanoseconds: UInt64,
        observesMutations: Bool,
        onArmed: @Sendable () -> Void
    ) async {
        guard delayNanoseconds > 0 else { return }
        let waiter = AgentHibernationRestoreDispatchWait()
        var sources: [any DispatchSourceProtocol] = []
        let transcriptDescriptor = observesMutations
            ? open(transcriptPath, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            : -1
        if transcriptDescriptor >= 0 {
            var status = stat()
            if fstat(transcriptDescriptor, &status) == 0,
               status.st_mode & S_IFMT == S_IFREG {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: transcriptDescriptor,
                    eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke],
                    queue: restoreMonitorEventQueue
                )
                source.setEventHandler { Task { await waiter.finish() } }
                source.setCancelHandler { Darwin.close(transcriptDescriptor) }
                sources.append(source)
            } else {
                Darwin.close(transcriptDescriptor)
            }
        }
        let directoryPath = (transcriptPath as NSString).deletingLastPathComponent
        let descriptor = observesMutations
            ? open(directoryPath, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            : -1
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: restoreMonitorEventQueue
            )
            source.setEventHandler { Task { await waiter.finish() } }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: restoreMonitorEventQueue)
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(clamping: delayNanoseconds)),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { Task { await waiter.finish() } }
        sources.append(timer)
        await waiter.wait(for: sources, onArmed: onArmed)
    }

    private static func nanoseconds(
        in duration: ContinuousClock.Duration
    ) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let secondNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if secondNanoseconds.overflow { return UInt64.max }
        let attoseconds = UInt64(max(0, components.attoseconds))
        let subsecondNanoseconds = attoseconds / 1_000_000_000
        let total = secondNanoseconds.partialValue.addingReportingOverflow(subsecondNanoseconds)
        return total.overflow ? UInt64.max : total.partialValue
    }

    private static func runRestoreChecksUntilBackstop(
        delayNanoseconds: UInt64,
        transcriptPath: String,
        clock: ContinuousClock,
        stopIfNoLongerCurrent: () async -> Bool,
        restoreBeforeStoppedReturn: () async -> Void,
        refreshSnapshotCommitProof: () -> Void,
        maximumMutationChecks: Int,
        onMutationWaitArmed: @Sendable () -> Void
    ) async -> (completed: Bool, consumedMutationChecks: Int) {
        let deadline = clock.now.advanced(
            by: .nanoseconds(Int64(clamping: delayNanoseconds))
        )
        var mutationChecks = 0
        repeat {
            var observedMutations = false
            if delayNanoseconds > 0 {
                let remainingNanoseconds = nanoseconds(in: clock.now.duration(to: deadline))
                if remainingNanoseconds > 0 {
                    observedMutations = mutationChecks < maximumMutationChecks
                    await waitForTranscriptMutationOrBackstop(
                        transcriptPath: transcriptPath,
                        delayNanoseconds: remainingNanoseconds,
                        observesMutations: observedMutations,
                        onArmed: onMutationWaitArmed
                    )
                }
            }
            if Task.isCancelled {
                await restoreBeforeStoppedReturn()
                return (false, mutationChecks)
            }
            if await stopIfNoLongerCurrent() { return (false, mutationChecks) }
            refreshSnapshotCommitProof()
            if observedMutations { mutationChecks += 1 }
        } while clock.now < deadline
        return (true, mutationChecks)
    }

    static func runPostTeardownRestoreChecks(
        snapshot: TeardownTranscriptSnapshot,
        processIDs: Set<Int>,
        initialRetryDelaysNanoseconds: [UInt64] = [0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000],
        backstopDelaysSeconds: [UInt64] = Self.restoreCheckDelaysSeconds,
        clock: ContinuousClock = ContinuousClock(),
        fileManager: FileManager = .default,
        snapshotDisposal: PostTeardownSnapshotDisposal = .deleteWhenSafe,
        shouldContinue: @Sendable () async -> Bool = { true },
        shouldRestoreOnCancellation: @Sendable () async -> Bool = { true },
        recoveryAuthorityRetired: @Sendable () async -> Void = {},
        processExitBackstopSeconds: Int = 30,
        maximumMutationChecksPerMonitor: Int = 4,
        onMutationWaitArmed: @Sendable () -> Void = {}
    ) async {
        var snapshotIsCommitted = false
        var retainSnapshot = false
        let snapshotFileVersion = stableRegularFileVersion(
            atPath: snapshot.snapshotPath,
            fileManager: fileManager
        )

        func refreshSnapshotCommitProof() {
            let restored = restoreIfClobbered(snapshot, fileManager: fileManager)
            // A populated live transcript can still be a divergent rewrite.
            // Only a successful restore or stable exact/prefix byte proof makes
            // the protected copy redundant.
            snapshotIsCommitted = restored || file(
                atPath: snapshot.transcriptPath,
                stablyContainsPrefixAtPath: snapshot.snapshotPath,
                fileManager: fileManager
            )
        }

        func restoreBeforeStoppedReturn() async {
            retainSnapshot = true
            guard await shouldRestoreOnCancellation() else { return }
            refreshSnapshotCommitProof()
        }

        func stopIfNoLongerCurrent() async -> Bool {
            guard await shouldContinue() else {
                await restoreBeforeStoppedReturn()
                return true
            }
            return false
        }

        defer {
            if !retainSnapshot, !Task.isCancelled {
                switch snapshotDisposal {
                case .deleteWhenSafe:
                    if snapshotIsCommitted {
                        if let snapshotFileVersion {
                            _ = durablyRemoveRecoverySnapshot(
                                atPath: snapshot.snapshotPath,
                                afterSynchronizingLivePath: snapshot.transcriptPath,
                                expectedSnapshotVersion: snapshotFileVersion
                            )
                        }
                    }
                case .retainForRecovery(let sessionId):
                    if snapshotIsCommitted {
                        if let snapshotFileVersion {
                            _ = durablyRemoveRecoverySnapshot(
                                atPath: snapshot.snapshotPath,
                                afterSynchronizingLivePath: snapshot.transcriptPath,
                                expectedSnapshotVersion: snapshotFileVersion
                            )
                        }
                    } else {
                        retainSnapshotForRecovery(snapshot, sessionId: sessionId, fileManager: fileManager)
                    }
                }
            }
        }

        guard await AgentHibernationRestoreMonitorScheduler.shared.acquire() else {
            await restoreBeforeStoppedReturn()
            return
        }
        defer { AgentHibernationRestoreMonitorScheduler.shared.release() }

        if !processIDs.isEmpty {
            var processIdentities: Set<AgentPIDProcessIdentity> = []
            var selectedProcessIDs: Set<Int> = []
            for identity in snapshot.guardedProcessIdentities.prefix(64)
                where processIDs.contains(Int(identity.pid)) {
                processIdentities.insert(identity)
                selectedProcessIDs.insert(Int(identity.pid))
            }
            var hasUnwatchedProcesses = snapshot.hasUncapturedGuardedProcesses
            var examinedProcessIDs = 0
            for processID in processIDs where !selectedProcessIDs.contains(processID) {
                examinedProcessIDs += 1
                if examinedProcessIDs > 256 || processIdentities.count >= 64 {
                    hasUnwatchedProcesses = true
                    break
                }
                guard processID > 0, processID <= Int(Int32.max) else { continue }
                if let identity = AgentPIDProcessIdentity(pid: pid_t(processID)) {
                    processIdentities.insert(identity)
                }
            }
            let allGuardedProcessesExited = await waitForGuardedProcessExitOrBackstop(
                processIdentities: processIdentities,
                hasUnwatchedProcesses: hasUnwatchedProcesses,
                backstopSeconds: processExitBackstopSeconds
            )
            if Task.isCancelled {
                await restoreBeforeStoppedReturn()
                return
            }
            if await stopIfNoLongerCurrent() { return }
            guard allGuardedProcessesExited else {
                // One total deadline bounds monitor resources. Keep durable
                // recovery authority when a process cannot be fully watched or
                // outlives the deadline; startup recovery can reconcile it.
                retainSnapshot = true
                refreshSnapshotCommitProof()
                return
            }
        }

        var remainingMutationChecks = max(0, maximumMutationChecksPerMonitor)
        for delayNanoseconds in initialRetryDelaysNanoseconds {
            let result = await runRestoreChecksUntilBackstop(
                delayNanoseconds: delayNanoseconds,
                transcriptPath: snapshot.transcriptPath,
                clock: clock,
                stopIfNoLongerCurrent: stopIfNoLongerCurrent,
                restoreBeforeStoppedReturn: restoreBeforeStoppedReturn,
                refreshSnapshotCommitProof: refreshSnapshotCommitProof,
                maximumMutationChecks: remainingMutationChecks,
                onMutationWaitArmed: onMutationWaitArmed
            )
            remainingMutationChecks = max(
                0,
                remainingMutationChecks - result.consumedMutationChecks
            )
            if !result.completed { return }
        }

        for delaySeconds in backstopDelaysSeconds {
            let nanoseconds = delaySeconds > UInt64.max / 1_000_000_000
                ? UInt64.max
                : delaySeconds * 1_000_000_000
            let result = await runRestoreChecksUntilBackstop(
                delayNanoseconds: nanoseconds,
                transcriptPath: snapshot.transcriptPath,
                clock: clock,
                stopIfNoLongerCurrent: stopIfNoLongerCurrent,
                restoreBeforeStoppedReturn: restoreBeforeStoppedReturn,
                refreshSnapshotCommitProof: refreshSnapshotCommitProof,
                maximumMutationChecks: remainingMutationChecks,
                onMutationWaitArmed: onMutationWaitArmed
            )
            remainingMutationChecks = max(
                0,
                remainingMutationChecks - result.consumedMutationChecks
            )
            if !result.completed { return }
        }

        guard !snapshotIsCommitted,
              let snapshotFileVersion,
              retireCurrentRecoveryOwner(
                for: snapshot,
                expectedSnapshotVersion: snapshotFileVersion,
                fileManager: fileManager
              ) else {
            return
        }
        // Retained-slot disposal must finish before recovery is enqueued, or a
        // scanner could claim the UUID path while it is being consolidated.
        if case .retainForRecovery(let sessionId) = snapshotDisposal {
            retainSnapshot = true
            retainSnapshotForRecovery(
                snapshot,
                sessionId: sessionId,
                fileManager: fileManager
            )
        }
        await recoveryAuthorityRetired()
    }
}

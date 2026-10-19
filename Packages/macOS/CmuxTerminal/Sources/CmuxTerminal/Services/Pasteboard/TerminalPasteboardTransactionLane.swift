import AppKit
import os

private let terminalPasteboardTransactionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "PasteboardTransaction"
)

/// Serializes cmux-owned reads and writes for one pasteboard without making
/// synchronous runtime callbacks await an actor hop.
///
/// SAFETY: the unfair lock owns all queue and active-operation state. AppKit
/// pasteboard work happens outside the lock while the active marker prevents a
/// second drainer from entering the same pasteboard.
final class TerminalPasteboardTransactionLane: @unchecked Sendable {
    private nonisolated(unsafe) let pasteboard: NSPasteboard
    private let maximumQueuedOperations: Int
    private let maximumQueuedWriteBytes: Int
    private let previousContentsCapture:
        TerminalPasteboardService.PreviousContentsCapture
    private let mutationApplier: TerminalPasteboardMutationApplier
    private let state = OSAllocatedUnfairLock(initialState: LaneState())

    init(
        pasteboard: NSPasteboard,
        maximumQueuedOperations: Int = defaultMaximumQueuedOperations,
        maximumQueuedWriteBytes: Int = defaultMaximumQueuedWriteBytes,
        previousContentsCapture: @escaping TerminalPasteboardService
            .PreviousContentsCapture,
        pasteboardWrite: TerminalPasteboardMutationApplier.PasteboardWrite? = nil
    ) {
        self.pasteboard = pasteboard
        self.maximumQueuedOperations = max(0, maximumQueuedOperations)
        self.maximumQueuedWriteBytes = max(0, maximumQueuedWriteBytes)
        self.previousContentsCapture = previousContentsCapture
        self.mutationApplier = TerminalPasteboardMutationApplier(
            pasteboard: pasteboard,
            pasteboardWrite: pasteboardWrite
        )
    }

    func reserveRead() -> TerminalPasteboardReadLease? {
        let admission = state.withLock {
            state -> (
                lease: TerminalPasteboardReadLease?,
                shouldDrain: Bool
            ) in
            let retainedOperationCount = state.entries.count
                + (state.activeReadID == nil ? 0 : 1)
                + (state.activeMutation == nil ? 0 : 1)
            guard retainedOperationCount < maximumQueuedOperations else {
                return (nil, false)
            }
            let id = state.nextID
            state.nextID &+= 1
            let lease = TerminalPasteboardReadLease(
                id: id,
                finishHandler: { [weak self] in
                    self?.finishRead(id: id)
                }
            )
            state.entries.append(.read(lease))
            let shouldDrain = state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.count == 1
            return (lease, shouldDrain)
        }
        if admission.shouldDrain {
            drain()
        }
        return admission.lease
    }

    @discardableResult
    func enqueueMutation(_ mutation: Mutation) -> Bool {
        let admission = admitMutation(
            mutation,
            lease: nil,
            coalescible: mutation.condition == nil
                && !mutation.capturesPreviousContents
        )
        switch admission {
        case .admitted(let shouldDrain):
            if shouldDrain { drain() }
            return true
        case .rejected:
            terminalPasteboardTransactionLogger.error(
                "Clipboard write dropped because the bounded transaction lane is full"
            )
            return false
        }
    }

    func reserveMutation(
        _ mutation: Mutation
    ) -> TerminalPasteboardMutationLease? {
        let retainedBytes = TerminalPasteboardItemSnapshot
            .retainedByteCount(of: mutation.contents)
        let admission = state.withLock {
            state -> (
                lease: TerminalPasteboardMutationLease?,
                shouldDrain: Bool
            ) in
            let retainedOperationCount = state.entries.count
                + (state.activeReadID == nil ? 0 : 1)
                + (state.activeMutation == nil ? 0 : 1)
            guard retainedOperationCount < maximumQueuedOperations else {
                return (nil, false)
            }
            let isIdle = state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.isEmpty
            guard isIdle
                    || (retainedBytes <= maximumQueuedWriteBytes
                        && state.retainedMutationBytes
                            <= maximumQueuedWriteBytes - retainedBytes) else {
                return (nil, false)
            }
            let id = state.nextID
            state.nextID &+= 1
            let lease = TerminalPasteboardMutationLease(
                id: id,
                finishHandler: { [weak self] in
                    self?.finishMutation(id: id)
                }
            )
            state.entries.append(.mutation(
                id: id,
                mutation: mutation,
                lease: lease,
                retainedBytes: retainedBytes,
                coalescible: false,
                isRestoration: false
            ))
            state.retainedMutationBytes += retainedBytes
            return (lease, isIdle)
        }
        if admission.shouldDrain { drain() }
        return admission.lease
    }

    private func admitMutation(
        _ mutation: Mutation,
        lease: TerminalPasteboardMutationLease?,
        coalescible: Bool
    ) -> MutationAdmission {
        let retainedBytes = TerminalPasteboardItemSnapshot
            .retainedByteCount(of: mutation.contents)
        return state.withLock { state -> MutationAdmission in
            let id = state.nextID
            state.nextID &+= 1

            let isIdle = state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.isEmpty
            if !isIdle,
               coalescible,
               state.entries.last?.isCoalescibleMutation == true {
                state.retainedMutationBytes -= state.entries.removeLast().retainedBytes
                guard retainedBytes <= maximumQueuedWriteBytes,
                      state.retainedMutationBytes
                        <= maximumQueuedWriteBytes - retainedBytes else {
                    return .rejected
                }
                state.entries.append(.mutation(
                    id: id,
                    mutation: mutation,
                    lease: nil,
                    retainedBytes: retainedBytes,
                    coalescible: true,
                    isRestoration: false
                ))
                state.retainedMutationBytes += retainedBytes
                return .admitted(shouldDrain: false)
            }

            let retainedOperationCount = state.entries.count
                + (state.activeReadID == nil ? 0 : 1)
                + (state.activeMutation == nil ? 0 : 1)
            guard retainedOperationCount < maximumQueuedOperations else {
                return .rejected
            }
            guard isIdle
                    || (retainedBytes <= maximumQueuedWriteBytes
                        && state.retainedMutationBytes
                            <= maximumQueuedWriteBytes - retainedBytes) else {
                return .rejected
            }
            state.entries.append(.mutation(
                id: id,
                mutation: mutation,
                lease: lease,
                retainedBytes: retainedBytes,
                coalescible: coalescible,
                isRestoration: false
            ))
            state.retainedMutationBytes += retainedBytes
            return .admitted(shouldDrain: isIdle)
        }
    }

    /// Admits one conditional clipboard restoration beyond the ordinary
    /// operation and byte caps.
    ///
    /// Only one restoration may occupy this reserved slot. Its payload was
    /// already captured under `maximumQueuedWriteBytes`, so the lane remains
    /// bounded while guaranteeing that temporary clipboard ownership cannot
    /// discard the user's sole rollback snapshot under queue pressure.
    func enqueueRestoration(_ mutation: Mutation) -> Bool {
        let retainedBytes = TerminalPasteboardItemSnapshot
            .retainedByteCount(of: mutation.contents)
        let admission = state.withLock {
            state -> (admitted: Bool, shouldDrain: Bool) in
            guard state.restorationOperationCount == 0,
                  retainedBytes <= maximumQueuedWriteBytes else {
                return (false, false)
            }
            let id = state.nextID
            state.nextID &+= 1
            let shouldDrain = state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.isEmpty
            state.entries.append(.mutation(
                id: id,
                mutation: mutation,
                lease: nil,
                retainedBytes: retainedBytes,
                coalescible: false,
                isRestoration: true
            ))
            state.retainedMutationBytes += retainedBytes
            state.restorationOperationCount += 1
            return (true, shouldDrain)
        }
        if admission.shouldDrain { drain() }
        return admission.admitted
    }

    private func finishRead(id: UInt64) {
        let shouldDrain = state.withLock { state -> Bool in
            if state.activeReadID == id {
                state.activeReadID = nil
                return true
            }
            guard let index = state.entries.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let removed = state.entries.remove(at: index)
            state.retainedMutationBytes -= removed.retainedBytes
            if removed.isRestoration {
                state.restorationOperationCount -= 1
            }
            return state.activeReadID == nil && state.activeMutation == nil
        }
        if shouldDrain {
            drain()
        }
    }

    private func drain() {
        while true {
            let action = state.withLock { state -> DrainAction? in
                guard state.activeReadID == nil,
                      state.activeMutation == nil,
                      !state.entries.isEmpty else {
                    return nil
                }
                let entry = state.entries.removeFirst()
                state.retainedMutationBytes -= entry.retainedBytes
                switch entry {
                case .read(let lease):
                    state.activeReadID = lease.id
                    return .beginRead(lease)
                case .mutation(
                    let id,
                    let mutation,
                    let lease,
                    _,
                    _,
                    _
                ):
                    state.activeMutation = ActiveMutation(id: id)
                    return .performMutation(
                        id: id,
                        mutation: mutation,
                        lease: lease,
                        isRestoration: entry.isRestoration
                    )
                }
            }
            guard let action else { return }
            switch action {
            case .beginRead(let lease):
                lease.signalReady()
                return
            case .performMutation(
                let id,
                let mutation,
                let lease,
                let isRestoration
            ):
                if mutation.capturesPreviousContents {
                    beginPreviousContentsCapture(
                        id: id,
                        mutation: mutation,
                        lease: lease,
                        isRestoration: isRestoration
                    )
                    return
                }
                let result = mutationApplier.apply(
                    mutation,
                    previousContents: nil
                )
                if finishAppliedMutation(
                    id: id,
                    result: result,
                    lease: lease,
                    isRestoration: isRestoration
                ) {
                    return
                }
            }
        }
    }

    private func beginPreviousContentsCapture(
        id: UInt64,
        mutation: Mutation,
        lease: TerminalPasteboardMutationLease?,
        isRestoration: Bool
    ) {
        let request = TerminalPasteboardContentsCaptureRequest(
            pasteboardName: pasteboard.name.rawValue,
            changeCount: pasteboard.changeCount,
            maximumByteCount: maximumQueuedWriteBytes
        )
        let previousContentsCapture = self.previousContentsCapture
        // Synchronous runtime callbacks cannot inherit an async task tree.
        // This short-lived bridge is retained and cancelled by the active
        // mutation; the injected app implementation owns a killable worker.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = await previousContentsCapture(request)
            self?.completePreviousContentsCapture(
                id: id,
                mutation: mutation,
                lease: lease,
                isRestoration: isRestoration,
                snapshot: snapshot
            )
        }
        let shouldCancel = state.withLock { state -> Bool in
            guard var active = state.activeMutation,
                  active.id == id else {
                return true
            }
            active.captureTask = task
            state.activeMutation = active
            return active.finishRequested
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func completePreviousContentsCapture(
        id: UInt64,
        mutation: Mutation,
        lease: TerminalPasteboardMutationLease?,
        isRestoration: Bool,
        snapshot: TerminalPasteboardContentsSnapshot?
    ) {
        let shouldApply = state.withLock { state -> Bool in
            guard var active = state.activeMutation,
                  active.id == id else {
                return false
            }
            active.captureTask = nil
            if active.finishRequested {
                if isRestoration {
                    state.restorationOperationCount -= 1
                }
                state.activeMutation = nil
                return false
            }
            state.activeMutation = active
            return true
        }
        guard shouldApply else {
            drain()
            return
        }

        let result: TerminalPasteboardMutationResult
        if let snapshot {
            result = mutationApplier.apply(
                mutation,
                previousContents: snapshot
            )
        } else {
            result = TerminalPasteboardMutationResult(
                status: .captureLimitExceeded,
                publishedContents: mutation.contents
            )
        }
        if !finishAppliedMutation(
            id: id,
            result: result,
            lease: lease,
            isRestoration: isRestoration
        ) {
            drain()
        }
    }

    /// Finalizes an application and returns whether its lease keeps the lane.
    private func finishAppliedMutation(
        id: UInt64,
        result: TerminalPasteboardMutationResult,
        lease: TerminalPasteboardMutationLease?,
        isRestoration: Bool
    ) -> Bool {
        // The lease state is the atomic handoff: if finish() won before this
        // signal, its caller received nil and the lane retains restoration
        // ownership. If the signal won, finish() returns the applied result.
        let laneMustRestore = lease?.signalApplied(result)
            == .laneMustRestore
        if laneMustRestore {
            mutationApplier.restoreAbandonedMutation(result)
        }

        let shouldKeepLease = state.withLock { state -> Bool in
            guard let active = state.activeMutation,
                  active.id == id else {
                return false
            }
            if lease != nil,
               !laneMustRestore,
               !active.finishRequested {
                state.activeMutation?.isApplying = false
                return true
            }
            if isRestoration {
                state.restorationOperationCount -= 1
            }
            state.activeMutation = nil
            return false
        }
        return shouldKeepLease
    }

    private func finishMutation(id: UInt64) {
        let outcome = state.withLock {
            state -> (shouldDrain: Bool, captureTask: Task<Void, Never>?) in
            if var active = state.activeMutation,
               active.id == id {
                if active.isApplying {
                    active.finishRequested = true
                    state.activeMutation = active
                    return (false, active.captureTask)
                }
                state.activeMutation = nil
                return (true, nil)
            }
            guard let index = state.entries.firstIndex(where: { $0.id == id }) else {
                return (false, nil)
            }
            let removed = state.entries.remove(at: index)
            state.retainedMutationBytes -= removed.retainedBytes
            if removed.isRestoration {
                state.restorationOperationCount -= 1
            }
            return (
                state.activeReadID == nil && state.activeMutation == nil,
                nil
            )
        }
        outcome.captureTask?.cancel()
        if outcome.shouldDrain { drain() }
    }

    /// Applies an unmanaged mutation synchronously on a newly created, idle
    /// lane. Managed standard/selection pasteboards must use queue admission;
    /// rollback capture is asynchronous and is therefore unsupported here.
    func applyUnmanagedMutation(_ mutation: Mutation) -> TerminalPasteboardMutationResult {
        precondition(!mutation.capturesPreviousContents)
        precondition(state.withLock { state in
            state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.isEmpty
        })
        return mutationApplier.apply(mutation, previousContents: nil)
    }

    var maximumRetainedMutationBytes: Int {
        maximumQueuedWriteBytes
    }

}

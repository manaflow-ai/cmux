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
    static let defaultMaximumQueuedOperations = 32
    static let defaultMaximumQueuedWriteBytes = 4 * 1_048_576

    enum MutationCondition: Sendable {
        case changeCount(Int)
        case contents([TerminalPasteboardItemSnapshot])
    }

    struct Mutation: Sendable {
        let contents: [TerminalPasteboardItemSnapshot]
        let condition: MutationCondition?
        let capturesPreviousContents: Bool
    }

    private enum Entry {
        case read(TerminalPasteboardReadLease)
        case mutation(
            id: UInt64,
            mutation: Mutation,
            lease: TerminalPasteboardMutationLease?,
            retainedBytes: Int,
            coalescible: Bool,
            isRestoration: Bool
        )

        var id: UInt64 {
            switch self {
            case .read(let lease):
                return lease.id
            case .mutation(let id, _, _, _, _, _):
                return id
            }
        }

        var retainedBytes: Int {
            guard case .mutation(
                _, _, _, let retainedBytes, _, _
            ) = self else {
                return 0
            }
            return retainedBytes
        }

        var isCoalescibleMutation: Bool {
            guard case .mutation(_, _, nil, _, true, false) = self else {
                return false
            }
            return true
        }

        var isRestoration: Bool {
            guard case .mutation(_, _, _, _, _, true) = self else {
                return false
            }
            return true
        }
    }

    private struct ActiveMutation {
        let id: UInt64
        var isApplying = true
        var finishRequested = false
    }

    private struct LaneState {
        var nextID: UInt64 = 0
        var activeReadID: UInt64?
        var activeMutation: ActiveMutation?
        var entries: [Entry] = []
        var retainedMutationBytes = 0
        var restorationOperationCount = 0
    }

    private enum DrainAction {
        case beginRead(TerminalPasteboardReadLease)
        case performMutation(
            id: UInt64,
            mutation: Mutation,
            lease: TerminalPasteboardMutationLease?,
            isRestoration: Bool
        )
    }

    private enum MutationAdmission {
        case admitted(shouldDrain: Bool)
        case rejected
    }

    private nonisolated(unsafe) let pasteboard: NSPasteboard
    private let maximumQueuedOperations: Int
    private let maximumQueuedWriteBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: LaneState())

    init(
        pasteboard: NSPasteboard,
        maximumQueuedOperations: Int = defaultMaximumQueuedOperations,
        maximumQueuedWriteBytes: Int = defaultMaximumQueuedWriteBytes
    ) {
        self.pasteboard = pasteboard
        self.maximumQueuedOperations = max(0, maximumQueuedOperations)
        self.maximumQueuedWriteBytes = max(0, maximumQueuedWriteBytes)
    }

    func reserveRead() -> TerminalPasteboardReadLease? {
        var shouldDrain = false
        let lease = state.withLock {
            state -> TerminalPasteboardReadLease? in
            let retainedOperationCount = state.entries.count
                + (state.activeReadID == nil ? 0 : 1)
                + (state.activeMutation == nil ? 0 : 1)
            guard retainedOperationCount < maximumQueuedOperations else {
                return nil
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
            shouldDrain = state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.count == 1
            return lease
        }
        if shouldDrain {
            drain()
        }
        return lease
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
        var shouldDrain = false
        let lease = state.withLock {
            state -> TerminalPasteboardMutationLease? in
            let retainedOperationCount = state.entries.count
                + (state.activeReadID == nil ? 0 : 1)
                + (state.activeMutation == nil ? 0 : 1)
            guard retainedOperationCount < maximumQueuedOperations else {
                return nil
            }
            let isIdle = state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.isEmpty
            guard isIdle
                    || (retainedBytes <= maximumQueuedWriteBytes
                        && state.retainedMutationBytes
                            <= maximumQueuedWriteBytes - retainedBytes) else {
                return nil
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
            shouldDrain = isIdle
            return lease
        }
        if shouldDrain { drain() }
        return lease
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
                let replacedBytes = state.entries.last?.retainedBytes ?? 0
                guard retainedBytes <= maximumQueuedWriteBytes,
                      state.retainedMutationBytes - replacedBytes
                        <= maximumQueuedWriteBytes - retainedBytes else {
                    return .rejected
                }
                state.entries[state.entries.count - 1] = .mutation(
                    id: id,
                    mutation: mutation,
                    lease: nil,
                    retainedBytes: retainedBytes,
                    coalescible: true,
                    isRestoration: false
                )
                state.retainedMutationBytes += retainedBytes - replacedBytes
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
        var shouldDrain = false
        let admitted = state.withLock { state -> Bool in
            guard state.restorationOperationCount == 0,
                  retainedBytes <= maximumQueuedWriteBytes else {
                return false
            }
            let id = state.nextID
            state.nextID &+= 1
            shouldDrain = state.activeReadID == nil
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
            return true
        }
        if shouldDrain { drain() }
        return admitted
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
                let result = apply(mutation)
                let shouldKeepLease = state.withLock { state -> Bool in
                    guard let active = state.activeMutation,
                          active.id == id else {
                        return false
                    }
                    if lease != nil, !active.finishRequested {
                        state.activeMutation?.isApplying = false
                        return true
                    }
                    if isRestoration {
                        state.restorationOperationCount -= 1
                    }
                    state.activeMutation = nil
                    return false
                }
                lease?.signalApplied(result)
                if shouldKeepLease {
                    return
                }
            }
        }
    }

    private func finishMutation(id: UInt64) {
        let shouldDrain = state.withLock { state -> Bool in
            if var active = state.activeMutation,
               active.id == id {
                if active.isApplying {
                    active.finishRequested = true
                    state.activeMutation = active
                    return false
                }
                state.activeMutation = nil
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
        if shouldDrain { drain() }
    }

    private func apply(_ mutation: Mutation) -> TerminalPasteboardMutationResult {
        switch mutation.condition {
        case .changeCount(let expectedChangeCount):
            guard pasteboard.changeCount == expectedChangeCount else {
                return TerminalPasteboardMutationResult(
                    status: .conditionNotMet,
                    publishedContents: mutation.contents
                )
            }
        case .contents(let expectedContents):
            guard let currentContents = TerminalPasteboardItemSnapshot
                    .captureContents(
                        of: pasteboard,
                        maximumByteCount: maximumQueuedWriteBytes
                    ),
                  currentContents == expectedContents else {
                return TerminalPasteboardMutationResult(
                    status: .conditionNotMet,
                    publishedContents: mutation.contents
                )
            }
        case nil:
            break
        }

        let previousContents: [TerminalPasteboardItemSnapshot]?
        if mutation.capturesPreviousContents {
            guard let captured = TerminalPasteboardItemSnapshot.captureContents(
                of: pasteboard,
                maximumByteCount: maximumQueuedWriteBytes
            ) else {
                return TerminalPasteboardMutationResult(
                    status: .captureLimitExceeded,
                    publishedContents: mutation.contents
                )
            }
            previousContents = captured
        } else {
            previousContents = nil
        }

        pasteboard.clearContents()
        let items = mutation.contents.compactMap { $0.makePasteboardItem() }
        let wrote = mutation.contents.isEmpty
            || (items.count == mutation.contents.count
                && pasteboard.writeObjects(items))
        return TerminalPasteboardMutationResult(
            status: wrote ? .written : .writeFailed,
            previousContents: previousContents,
            publishedContents: mutation.contents
        )
    }

    func applyUnmanagedMutation(_ mutation: Mutation) -> TerminalPasteboardMutationResult {
        apply(mutation)
    }

    var maximumRetainedMutationBytes: Int {
        maximumQueuedWriteBytes
    }

    var isIdleForTesting: Bool {
        state.withLock { state in
            state.activeReadID == nil
                && state.activeMutation == nil
                && state.entries.isEmpty
        }
    }
}

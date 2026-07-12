import CMUXMobileCore
import Foundation

/// One mounted surface's optimistic-scroll transaction owner.
///
/// Local Ghostty mutations enter the surface's terminal mutation stream while
/// network scroll requests remain independent. Receipts join both paths before
/// authoritative reconciliation. A click then crosses a no-op surface barrier
/// before advancing the epoch, and later scroll intent remains bounded behind it.
@MainActor
final class TerminalScrollSession {
    typealias EnqueueLocal = @MainActor @Sendable (
        _ runs: [MobileTerminalScrollRun]
    ) -> TerminalSurfaceMutationReceipt
    typealias EnqueueBarrier = @MainActor @Sendable () -> TerminalSurfaceMutationReceipt
    typealias EnqueueScrollToBottom = @MainActor @Sendable () -> TerminalSurfaceMutationReceipt
    typealias CancelLocal = @MainActor @Sendable () -> Void
    typealias SendRemote = @MainActor @Sendable (TerminalScrollRequest) async -> TerminalScrollResponse?
    typealias SendClick = @MainActor @Sendable (
        _ surfaceID: String,
        _ interactionEpoch: UInt64,
        _ col: Int,
        _ row: Int
    ) async -> Bool
    typealias SupportsOrderedRemoteRuns = @MainActor @Sendable () -> Bool
    typealias PrepareIntent = @MainActor @Sendable () -> Void
    typealias DeliverAuthoritative = @MainActor @Sendable (
        _ frame: MobileTerminalRenderGridFrame,
        _ interactionEpoch: UInt64,
        _ clientRevision: UInt64
    ) -> Bool
    typealias CompleteGridlessAuthoritative = @MainActor @Sendable (_ renderRevision: UInt64?) -> Bool
    typealias ReconciliationDidComplete = @MainActor @Sendable () -> Void
    typealias RequestReplay = @MainActor @Sendable (_ interactionEpoch: UInt64) -> Void
    typealias AdvanceEpoch = @MainActor @Sendable () -> UInt64

    struct LocalReceiptEntry {
        let id: UUID
        let interactionEpoch: UInt64
        var clientRevision: UInt64
        let receipt: TerminalSurfaceMutationReceipt
    }

    struct RemoteInteraction {
        let id: UUID
        var kind: Kind

        enum Kind {
            case scroll(TerminalScrollRequest)
            case click(epoch: UInt64, col: Int, row: Int, clickID: UUID)
        }
    }

    struct PendingScrollIntent {
        let lines: Double
        let col: Int
        let row: Int
    }

    struct PendingClickIntent {
        let id: UUID
        let col: Int
        let row: Int
    }

    enum PendingClickState {
        case waiting(id: UUID, col: Int, row: Int)
        case waitingForBarrier(id: UUID, col: Int, row: Int)
        case sending(id: UUID, epoch: UInt64, col: Int, row: Int)

        var id: UUID {
            switch self {
            case .waiting(let id, _, _), .waitingForBarrier(let id, _, _), .sending(let id, _, _, _):
                id
            }
        }
    }

    static let maximumQueuedInteractionCount = 64

    let token: UUID
    let surfaceID: String
    let enqueueLocal: EnqueueLocal
    let enqueueBarrier: EnqueueBarrier
    let enqueueScrollToBottom: EnqueueScrollToBottom
    let cancelLocal: CancelLocal
    let sendRemote: SendRemote
    let sendClick: SendClick
    let supportsOrderedRemoteRuns: SupportsOrderedRemoteRuns
    let prepareIntent: PrepareIntent
    let deliverAuthoritative: DeliverAuthoritative
    let completeGridlessAuthoritative: CompleteGridlessAuthoritative
    let reconciliationDidComplete: ReconciliationDidComplete
    let requestReplay: RequestReplay
    let advanceEpoch: AdvanceEpoch

    var interactionEpoch: UInt64
    var latestClientRevision: UInt64 = 0
    var latestReconciledRevision: UInt64 = 0
    var isAwaitingAuthoritativeReconciliation = false

    var latestLocallyAppliedRevision: UInt64 = 0
    var localInFlight: LocalReceiptEntry?
    var localPending = BoundedFIFO<LocalReceiptEntry>(capacity: maximumQueuedInteractionCount)
    var localReceiptTask: Task<Void, Never>?
    var remoteInFlight: RemoteInteraction?
    var remotePending = BoundedFIFO<RemoteInteraction>(capacity: maximumQueuedInteractionCount)
    var pendingResponse: TerminalScrollResponse?
    var remoteTask: Task<Void, Never>?
    var barrierTask: Task<Void, Never>?
    var pendingClick: PendingClickState?
    var pendingClicks = BoundedFIFO<PendingClickIntent>(capacity: maximumQueuedInteractionCount)
    var postClickIntents = BoundedFIFO<PendingScrollIntent>(capacity: maximumQueuedInteractionCount)
    var postClickNeedsSettlement = false
    var needsBottomSnap = true
    var bottomSnapReceiptGeneration: UInt64 = 0
    var bottomSnapReceiptTask: Task<Void, Never>?
    var accumulatedRowsSincePrefetch = 0.0
    var hasPrimedPrefetch = false
    var lastDirectionLines = 1.0
    var lastCol = 0
    var lastRow = 0

    var replayPrefetchWindow: TerminalScrollPrefetchWindow {
        .directional(for: lastDirectionLines)
    }

    init(
        token: UUID = UUID(),
        surfaceID: String,
        interactionEpoch: UInt64,
        enqueueLocal: @escaping EnqueueLocal,
        enqueueBarrier: @escaping EnqueueBarrier,
        enqueueScrollToBottom: @escaping EnqueueScrollToBottom,
        cancelLocal: @escaping CancelLocal,
        sendRemote: @escaping SendRemote,
        sendClick: @escaping SendClick = { _, _, _, _ in false },
        supportsOrderedRemoteRuns: @escaping SupportsOrderedRemoteRuns = { false },
        prepareIntent: @escaping PrepareIntent,
        deliverAuthoritative: @escaping DeliverAuthoritative,
        completeGridlessAuthoritative: @escaping CompleteGridlessAuthoritative,
        reconciliationDidComplete: @escaping ReconciliationDidComplete,
        requestReplay: @escaping RequestReplay,
        advanceEpoch: @escaping AdvanceEpoch
    ) {
        self.token = token
        self.surfaceID = surfaceID
        self.interactionEpoch = interactionEpoch
        self.enqueueLocal = enqueueLocal
        self.enqueueBarrier = enqueueBarrier
        self.enqueueScrollToBottom = enqueueScrollToBottom
        self.cancelLocal = cancelLocal
        self.sendRemote = sendRemote
        self.sendClick = sendClick
        self.supportsOrderedRemoteRuns = supportsOrderedRemoteRuns
        self.prepareIntent = prepareIntent
        self.deliverAuthoritative = deliverAuthoritative
        self.completeGridlessAuthoritative = completeGridlessAuthoritative
        self.reconciliationDidComplete = reconciliationDidComplete
        self.requestReplay = requestReplay
        self.advanceEpoch = advanceEpoch
    }

    func submit(lines: Double, col: Int, row: Int) {
        guard lines != 0 else { return }
        needsBottomSnap = true
        if pendingClick != nil {
            let appended = postClickIntents.append(PendingScrollIntent(
                lines: lines,
                col: max(0, col),
                row: max(0, row)
            ))
            if !appended { recoverFromLaneFailure() }
            return
        }
        submitInCurrentEpoch(lines: lines, col: col, row: row)
    }

    func submitInCurrentEpoch(lines: Double, col: Int, row: Int) {
        latestClientRevision &+= 1
        if latestClientRevision == 0 { latestClientRevision = 1 }
        prepareIntent()
        lastDirectionLines = lines
        lastCol = max(0, col)
        lastRow = max(0, row)
        let request = TerminalScrollRequest(
            surfaceID: surfaceID,
            interactionEpoch: interactionEpoch,
            clientRevision: latestClientRevision,
            lines: lines,
            col: lastCol,
            row: lastRow,
            prefetchWindow: prefetchWindow(for: lines)
        )
        isAwaitingAuthoritativeReconciliation = true
        enqueueLocalReceipt(for: request)
        enqueueRemote(RemoteInteraction(id: UUID(), kind: .scroll(request)))
    }

    func interactionDidBegin() {}

    func submitClick(col: Int, row: Int) {
        let intent = PendingClickIntent(id: UUID(), col: max(0, col), row: max(0, row))
        guard pendingClick != nil else {
            pendingClick = .waiting(id: intent.id, col: intent.col, row: intent.row)
            tryBeginClickBarrier()
            return
        }
        if !pendingClicks.append(intent) { recoverFromLaneFailure() }
    }

    func interactionDidEnd() {
        guard latestClientRevision > 0 else { return }
        if pendingClick != nil {
            postClickNeedsSettlement = true
            return
        }
        enqueueSettlement()
    }

    func invalidateForInput() -> UInt64 {
        invalidate(nextEpoch: advanceEpoch(), cancelLocalInteraction: true)
        enqueueBottomSnapIfNeeded()
        return interactionEpoch
    }

    func invalidateForRecovery() -> UInt64 {
        needsBottomSnap = true
        invalidate(nextEpoch: advanceEpoch(), cancelLocalInteraction: false)
        return interactionEpoch
    }

    func cancelForUnmount(nextEpoch: UInt64) {
        bottomSnapReceiptGeneration &+= 1
        bottomSnapReceiptTask?.cancel()
        bottomSnapReceiptTask = nil
        invalidate(nextEpoch: nextEpoch, cancelLocalInteraction: false)
    }

    var shouldDeferLiveRenderGrid: Bool {
        isAwaitingAuthoritativeReconciliation
    }

    private func prefetchWindow(for lines: Double) -> TerminalScrollPrefetchWindow? {
        accumulatedRowsSincePrefetch += abs(lines)
        guard !hasPrimedPrefetch
                || accumulatedRowsSincePrefetch >= TerminalScrollPrefetchWindow.refreshDistanceRows else {
            return nil
        }
        hasPrimedPrefetch = true
        accumulatedRowsSincePrefetch = 0
        return .directional(for: lines)
    }

    func enqueueSettlement() {
        enqueueRemote(RemoteInteraction(
            id: UUID(),
            kind: .scroll(TerminalScrollRequest(
                surfaceID: surfaceID,
                interactionEpoch: interactionEpoch,
                clientRevision: latestClientRevision,
                lines: 0,
                col: lastCol,
                row: lastRow,
                prefetchWindow: .directional(for: lastDirectionLines)
            ))
        ))
    }

    private func enqueueLocalReceipt(for request: TerminalScrollRequest) {
        let receipt = enqueueLocal(request.directionalRuns)
        let entry = LocalReceiptEntry(
            id: UUID(),
            interactionEpoch: request.interactionEpoch,
            clientRevision: request.clientRevision,
            receipt: receipt
        )
        guard localInFlight != nil else {
            startLocalReceipt(entry)
            return
        }
        if localInFlight?.receipt === receipt {
            localInFlight?.clientRevision = request.clientRevision
            return
        }
        var mergedPendingReceipt = false
        _ = localPending.mutateLast { pending in
            guard pending.receipt === receipt else { return false }
            pending.clientRevision = request.clientRevision
            mergedPendingReceipt = true
            return true
        }
        if mergedPendingReceipt { return }
        if !localPending.append(entry) { recoverFromLaneFailure() }
    }

    private func startLocalReceipt(_ entry: LocalReceiptEntry) {
        localInFlight = entry
        localReceiptTask = Task { @MainActor [weak self] in
            let applied = await entry.receipt.value
            self?.completeLocalReceipt(entry, applied: applied)
        }
    }

    private func completeLocalReceipt(_ entry: LocalReceiptEntry, applied: Bool) {
        guard let completedEntry = localInFlight,
              completedEntry.id == entry.id else { return }
        localInFlight = nil
        localReceiptTask = nil
        guard applied else {
            recoverFromLaneFailure()
            return
        }
        if completedEntry.interactionEpoch == interactionEpoch {
            latestLocallyAppliedRevision = max(
                latestLocallyAppliedRevision,
                completedEntry.clientRevision
            )
        }
        if let next = localPending.removeFirst() { startLocalReceipt(next) }
        reconcileIfReady()
        tryBeginClickBarrier()
    }

    func authoritativeDidApply(interactionEpoch: UInt64, clientRevision: UInt64) {
        completeReconciliation(
            interactionEpoch: interactionEpoch,
            clientRevision: clientRevision
        )
    }

    func completeReconciliation(interactionEpoch: UInt64, clientRevision: UInt64) {
        guard interactionEpoch == self.interactionEpoch,
              clientRevision == latestClientRevision,
              latestLocallyAppliedRevision >= clientRevision else {
            return
        }
        latestReconciledRevision = clientRevision
        isAwaitingAuthoritativeReconciliation = false
        reconciliationDidComplete()
        tryBeginClickBarrier()
    }

    func recoverFromLaneFailure() {
        let nextEpoch = advanceEpoch()
        needsBottomSnap = true
        invalidate(nextEpoch: nextEpoch, cancelLocalInteraction: false)
        requestReplay(nextEpoch)
    }

    private func enqueueBottomSnapIfNeeded() {
        guard needsBottomSnap else { return }
        needsBottomSnap = false
        bottomSnapReceiptGeneration &+= 1
        if bottomSnapReceiptGeneration == 0 { bottomSnapReceiptGeneration = 1 }
        let generation = bottomSnapReceiptGeneration
        let receipt = enqueueScrollToBottom()
        bottomSnapReceiptTask?.cancel()
        bottomSnapReceiptTask = Task { @MainActor [weak self] in
            let applied = await receipt.value
            guard let self, self.bottomSnapReceiptGeneration == generation else { return }
            self.bottomSnapReceiptTask = nil
            if !applied { self.needsBottomSnap = true }
        }
    }

    private func invalidate(nextEpoch: UInt64, cancelLocalInteraction: Bool) {
        localReceiptTask?.cancel()
        localReceiptTask = nil
        remoteTask?.cancel()
        remoteTask = nil
        barrierTask?.cancel()
        barrierTask = nil
        localInFlight = nil
        localPending.removeAll()
        remoteInFlight = nil
        remotePending.removeAll()
        pendingResponse = nil
        pendingClick = nil
        pendingClicks.removeAll()
        postClickIntents.removeAll()
        postClickNeedsSettlement = false
        interactionEpoch = nextEpoch
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        isAwaitingAuthoritativeReconciliation = false
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
        if cancelLocalInteraction { cancelLocal() }
    }
}

import CMUXMobileCore
import Foundation

/// One mounted surface's complete optimistic-scroll transaction owner.
///
/// Local Ghostty work and Mac RPC work drain independently so network latency
/// cannot slow UIKit tracking and a stalled local C call cannot starve Mac
/// authority. Consecutive scrolls coalesce in fixed-capacity interaction FIFOs;
/// clicks remain ordering barriers in both lanes. A Mac snapshot reconciles only
/// when it echoes the current epoch and newest client revision and all matching
/// local work has completed.
@MainActor
final class TerminalScrollSession {
    typealias ApplyLocal = @MainActor @Sendable (_ runs: [MobileTerminalScrollRun]) async -> Bool
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

    let token: UUID
    let surfaceID: String

    private let applyLocal: ApplyLocal
    private let cancelLocal: CancelLocal
    private let sendRemote: SendRemote
    private let sendClick: SendClick
    private let supportsOrderedRemoteRuns: SupportsOrderedRemoteRuns
    private let prepareIntent: PrepareIntent
    private let deliverAuthoritative: DeliverAuthoritative
    private let completeGridlessAuthoritative: CompleteGridlessAuthoritative
    private let reconciliationDidComplete: ReconciliationDidComplete
    private let requestReplay: RequestReplay
    private let advanceEpoch: AdvanceEpoch

    private(set) var interactionEpoch: UInt64
    private(set) var latestClientRevision: UInt64 = 0
    private(set) var latestReconciledRevision: UInt64 = 0
    private(set) var isAwaitingAuthoritativeReconciliation = false

    private var latestLocallyAppliedRevision: UInt64 = 0
    private struct LocalInteraction {
        let id: UUID
        var kind: Kind

        enum Kind {
            case scroll(TerminalScrollRequest)
            case clickBarrier(UUID)
        }
    }

    private struct RemoteInteraction {
        let id: UUID
        var kind: Kind

        enum Kind {
            case scroll(TerminalScrollRequest)
            case click(epoch: UInt64, col: Int, row: Int, barrierID: UUID)
        }
    }

    private static let maximumQueuedInteractionCount = 64
    private var localInFlight: LocalInteraction?
    private var localPending = BoundedFIFO<LocalInteraction>(
        capacity: TerminalScrollSession.maximumQueuedInteractionCount
    )
    private var remoteInFlight: RemoteInteraction?
    private var remotePending = BoundedFIFO<RemoteInteraction>(
        capacity: TerminalScrollSession.maximumQueuedInteractionCount
    )
    private var readyClickBarriers: Set<UUID> = []
    private var pendingResponse: TerminalScrollResponse?
    private var localTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var accumulatedRowsSincePrefetch = 0.0
    private var hasPrimedPrefetch = false
    private var lastDirectionLines = 1.0
    private var lastCol = 0
    private var lastRow = 0

    /// Bounded history needed to reconstruct this mounted surface after replay.
    /// The direction survives connection invalidation so reconnect, renderer
    /// recovery, and cold attach all refill the side the user was moving toward.
    var replayPrefetchWindow: TerminalScrollPrefetchWindow {
        .directional(for: lastDirectionLines)
    }

    init(
        token: UUID = UUID(),
        surfaceID: String,
        interactionEpoch: UInt64,
        applyLocal: @escaping ApplyLocal,
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
        self.applyLocal = applyLocal
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
        latestClientRevision &+= 1
        if latestClientRevision == 0 { latestClientRevision = 1 }
        // Stamp the newer revision before invalidating an unclaimed
        // reconciliation delivery so any stale apply acknowledgement cannot
        // complete the new intent.
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
        guard enqueueLocal(LocalInteraction(id: UUID(), kind: .scroll(request))) else { return }
        enqueueRemote(RemoteInteraction(id: UUID(), kind: .scroll(request)))
    }

    func interactionDidBegin() {}

    /// Orders a click after every preceding local and remote scroll operation.
    /// Advancing the epoch at submission fences older host scrolls without
    /// cancelling local optimistic work or snapping the viewport to the bottom.
    func submitClick(col: Int, row: Int) {
        let barrierID = UUID()
        advanceForClick(nextEpoch: advanceEpoch())
        guard enqueueLocal(LocalInteraction(
            id: UUID(),
            kind: .clickBarrier(barrierID)
        )) else {
            return
        }
        enqueueRemote(RemoteInteraction(
            id: UUID(),
            kind: .click(
                epoch: interactionEpoch,
                col: max(0, col),
                row: max(0, row),
                barrierID: barrierID
            )
        ))
    }

    /// Requests one final large directional window without relying on a quiet
    /// period timer. UIKit calls this only after drag and deceleration settle.
    func interactionDidEnd() {
        guard latestClientRevision > 0 else { return }
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

    func invalidateForInput() -> UInt64 {
        invalidate(nextEpoch: advanceEpoch(), snapToBottom: true)
        return interactionEpoch
    }

    func invalidateForRecovery() -> UInt64 {
        invalidate(nextEpoch: advanceEpoch(), snapToBottom: false)
        return interactionEpoch
    }

    func cancelForUnmount(nextEpoch: UInt64) {
        invalidate(nextEpoch: nextEpoch, snapToBottom: false)
    }

    /// Live event frames lack a client-intent acknowledgement. Applying one
    /// while an optimistic intent is unresolved can repaint a pre-scroll
    /// viewport over the local mirror even when its PTY byte sequence matches.
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

    private func enqueueLocal(_ interaction: LocalInteraction) -> Bool {
        guard localInFlight != nil else {
            startLocal(interaction)
            return true
        }
        if case .scroll(let newerRequest) = interaction.kind {
            var matchedPendingScroll = false
            let appended = localPending.mutateLast { pending in
               guard case .scroll(var request) = pending.kind,
                     request.interactionEpoch == newerRequest.interactionEpoch else {
                   return false
               }
               matchedPendingScroll = true
               guard request.append(newerRequest) else { return false }
               pending.kind = .scroll(request)
               return true
            }
            if matchedPendingScroll {
                guard appended else {
                    recoverFromLaneFailure()
                    return false
                }
                return true
            }
        }
        guard localPending.append(interaction) else {
            recoverFromLaneFailure()
            return false
        }
        return true
    }

    private func startLocal(_ interaction: LocalInteraction) {
        localInFlight = interaction
        localTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch interaction.kind {
            case .scroll(let request):
                let applied: Bool
                if request.directionalRuns.isEmpty {
                    applied = true
                } else {
                    applied = await self.applyLocal(request.directionalRuns)
                }
                self.completeLocal(interaction, applied: applied)
            case .clickBarrier(let barrierID):
                self.readyClickBarriers.insert(barrierID)
                self.completeLocal(interaction, applied: true)
            }
        }
    }

    private func completeLocal(_ interaction: LocalInteraction, applied: Bool) {
        guard localInFlight?.id == interaction.id else { return }
        localInFlight = nil
        localTask = nil
        guard applied else {
            recoverFromLaneFailure()
            return
        }
        if case .scroll(let request) = interaction.kind,
           request.interactionEpoch == interactionEpoch {
            latestLocallyAppliedRevision = max(latestLocallyAppliedRevision, request.clientRevision)
        }
        if let next = localPending.removeFirst() {
            startLocal(next)
        }
        drainRemoteIfReady()
        reconcileIfReady()
    }

    private func enqueueRemote(_ interaction: RemoteInteraction) {
        guard remoteInFlight != nil || remotePending.count > 0 else {
            if canStartRemote(interaction) {
                startRemote(interaction)
            } else if !remotePending.append(interaction) {
                recoverFromLaneFailure()
            }
            return
        }
        if case .scroll(let newerRequest) = interaction.kind {
            var matchedPendingScroll = false
            let appended = remotePending.mutateLast { pending in
               guard case .scroll(var request) = pending.kind,
                     request.interactionEpoch == newerRequest.interactionEpoch else {
                   return false
               }
               matchedPendingScroll = true
               guard request.append(newerRequest) else { return false }
               pending.kind = .scroll(request)
               return true
            }
            if matchedPendingScroll {
                guard appended else {
                    recoverFromLaneFailure()
                    return
                }
                return
            }
        }
        if !remotePending.append(interaction) {
            recoverFromLaneFailure()
            return
        }
        drainRemoteIfReady()
    }

    private func canStartRemote(_ interaction: RemoteInteraction) -> Bool {
        guard case .click(_, _, _, let barrierID) = interaction.kind else { return true }
        return readyClickBarriers.contains(barrierID)
    }

    private func drainRemoteIfReady() {
        guard remoteInFlight == nil,
              let next = remotePending.first,
              canStartRemote(next) else {
            return
        }
        _ = remotePending.removeFirst()
        startRemote(next)
    }

    private func startRemote(_ interaction: RemoteInteraction) {
        remoteInFlight = interaction
        remoteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch interaction.kind {
            case .scroll(let request):
                let plannedRequests = request.plannedRPCRequests(
                    supportsOrderedRuns: self.supportsOrderedRemoteRuns()
                )
                var response: TerminalScrollResponse?
                for plannedRequest in plannedRequests {
                    guard !Task.isCancelled else { return }
                    guard let plannedResponse = await self.sendRemote(plannedRequest),
                          plannedResponse.accepted,
                          plannedResponse.interactionEpoch == request.interactionEpoch,
                          plannedResponse.clientRevision == request.clientRevision else {
                        self.completeRemote(interaction, response: nil, succeeded: false)
                        return
                    }
                    response = plannedResponse
                }
                self.completeRemote(interaction, response: response, succeeded: true)
            case .click(let epoch, let col, let row, _):
                let succeeded = await self.sendClick(self.surfaceID, epoch, col, row)
                self.completeRemote(interaction, response: nil, succeeded: succeeded)
            }
        }
    }

    private func completeRemote(
        _ interaction: RemoteInteraction,
        response: TerminalScrollResponse?,
        succeeded: Bool
    ) {
        guard remoteInFlight?.id == interaction.id else { return }
        remoteInFlight = nil
        remoteTask = nil
        guard succeeded else {
            recoverFromLaneFailure()
            return
        }

        switch interaction.kind {
        case .scroll(let request):
            if request.interactionEpoch == interactionEpoch, let response {
                if response.clientRevision == latestClientRevision {
                    if pendingResponse?.renderGrid == nil || response.renderGrid != nil {
                        pendingResponse = response
                    }
                } else if response.renderGrid != nil {
                    remotePending.mutateFirst { pending in
                        guard case .scroll(var pendingRequest) = pending.kind,
                              pendingRequest.prefetchWindow == nil else {
                            return
                        }
                        pendingRequest.prefetchWindow = request.prefetchWindow
                        pending.kind = .scroll(pendingRequest)
                    }
                }
            }
        case .click(_, _, _, let barrierID):
            readyClickBarriers.remove(barrierID)
        }

        drainRemoteIfReady()
        reconcileIfReady()
    }

    private func reconcileIfReady() {
        guard let response = pendingResponse,
              response.interactionEpoch == interactionEpoch,
              response.clientRevision == latestClientRevision,
              latestLocallyAppliedRevision >= response.clientRevision else {
            return
        }
        pendingResponse = nil
        if let frame = response.renderGrid {
            guard deliverAuthoritative(
                frame,
                response.interactionEpoch,
                response.clientRevision
            ) else {
                recoverFromLaneFailure()
                return
            }
            return
        }
        guard completeGridlessAuthoritative(response.renderRevision) else {
            recoverFromLaneFailure()
            return
        }
        completeReconciliation(
            interactionEpoch: response.interactionEpoch,
            clientRevision: response.clientRevision
        )
    }

    /// Completes a frame-backed reconciliation only after the exact output
    /// delivery has reached the current Ghostty surface generation.
    func authoritativeDidApply(interactionEpoch: UInt64, clientRevision: UInt64) {
        completeReconciliation(
            interactionEpoch: interactionEpoch,
            clientRevision: clientRevision
        )
    }

    private func completeReconciliation(interactionEpoch: UInt64, clientRevision: UInt64) {
        guard interactionEpoch == self.interactionEpoch,
              clientRevision == latestClientRevision,
              latestLocallyAppliedRevision >= clientRevision else {
            return
        }
        latestReconciledRevision = clientRevision
        isAwaitingAuthoritativeReconciliation = false
        reconciliationDidComplete()
    }

    private func recoverFromLaneFailure() {
        let nextEpoch = advanceEpoch()
        invalidate(nextEpoch: nextEpoch, snapToBottom: false)
        requestReplay(nextEpoch)
    }

    private func advanceForClick(nextEpoch: UInt64) {
        pendingResponse = nil
        interactionEpoch = nextEpoch
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        isAwaitingAuthoritativeReconciliation = false
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
    }

    private func invalidate(nextEpoch: UInt64, snapToBottom: Bool) {
        localTask?.cancel()
        localTask = nil
        remoteTask?.cancel()
        remoteTask = nil
        localInFlight = nil
        localPending.removeAll()
        remoteInFlight = nil
        remotePending.removeAll()
        readyClickBarriers.removeAll()
        pendingResponse = nil
        interactionEpoch = nextEpoch
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        isAwaitingAuthoritativeReconciliation = false
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
        if snapToBottom {
            cancelLocal()
        }
    }
}

private struct BoundedFIFO<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    mutating func append(_ element: Element) -> Bool {
        guard count < storage.count else { return false }
        let index = (head + count) % storage.count
        storage[index] = element
        count += 1
        return true
    }

    mutating func removeFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }

    mutating func mutateFirst(_ body: (inout Element) -> Void) {
        guard count > 0, var element = storage[head] else { return }
        body(&element)
        storage[head] = element
    }

    mutating func mutateLast(_ body: (inout Element) -> Bool) -> Bool {
        guard count > 0 else { return false }
        let index = (head + count - 1) % storage.count
        guard var element = storage[index], body(&element) else { return false }
        storage[index] = element
        return true
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }
}

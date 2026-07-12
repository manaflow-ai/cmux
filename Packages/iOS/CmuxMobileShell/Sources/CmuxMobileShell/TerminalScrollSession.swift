import CMUXMobileCore
import Foundation

/// One mounted surface's complete optimistic-scroll transaction owner.
///
/// Local Ghostty work and Mac RPC work drain independently so network latency
/// cannot slow UIKit tracking and a stalled local C call cannot starve Mac
/// authority. Each lane retains one in-flight batch and one newest pending
/// batch. A Mac snapshot reconciles only when it echoes the current epoch and
/// newest client revision and all matching local work has completed.
@MainActor
final class TerminalScrollSession {
    typealias ApplyLocal = @MainActor @Sendable (_ runs: [MobileTerminalScrollRun]) async -> Bool
    typealias CancelLocal = @MainActor @Sendable () -> Void
    typealias SendRemote = @MainActor @Sendable (TerminalScrollRequest) async -> TerminalScrollResponse?
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
    private var localInFlight: TerminalScrollRequest?
    private var localPending: TerminalScrollRequest?
    private var remoteInFlight: TerminalScrollRequest?
    private var remotePending: TerminalScrollRequest?
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
        guard enqueueLocal(request) else { return }
        enqueueRemote(request)
    }

    func interactionDidBegin() {}

    /// Requests one final large directional window without relying on a quiet
    /// period timer. UIKit calls this only after drag and deceleration settle.
    func interactionDidEnd() {
        guard latestClientRevision > 0 else { return }
        enqueueRemote(TerminalScrollRequest(
            surfaceID: surfaceID,
            interactionEpoch: interactionEpoch,
            clientRevision: latestClientRevision,
            lines: 0,
            col: lastCol,
            row: lastRow,
            prefetchWindow: .directional(for: lastDirectionLines)
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

    private func enqueueLocal(_ request: TerminalScrollRequest) -> Bool {
        guard localInFlight == nil else {
            if var pending = localPending {
                guard pending.append(request) else {
                    recoverFromLaneFailure()
                    return false
                }
                localPending = pending
            } else {
                localPending = request
            }
            return true
        }
        startLocal(request)
        return true
    }

    private func startLocal(_ request: TerminalScrollRequest) {
        localInFlight = request
        localTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let applied: Bool
            if request.directionalRuns.isEmpty {
                applied = true
            } else {
                applied = await self.applyLocal(request.directionalRuns)
            }
            self.completeLocal(request, applied: applied)
        }
    }

    private func completeLocal(_ request: TerminalScrollRequest, applied: Bool) {
        guard localInFlight?.interactionEpoch == request.interactionEpoch,
              localInFlight?.clientRevision == request.clientRevision else {
            return
        }
        localInFlight = nil
        localTask = nil
        guard request.interactionEpoch == interactionEpoch else { return }
        guard applied else {
            recoverFromLaneFailure()
            return
        }
        latestLocallyAppliedRevision = max(latestLocallyAppliedRevision, request.clientRevision)
        if let next = localPending {
            localPending = nil
            startLocal(next)
        }
        reconcileIfReady()
    }

    private func enqueueRemote(_ request: TerminalScrollRequest) {
        guard remoteInFlight == nil else {
            if var pending = remotePending {
                guard pending.append(request) else {
                    recoverFromLaneFailure()
                    return
                }
                remotePending = pending
            } else {
                remotePending = request
            }
            return
        }
        startRemote(request)
    }

    private func startRemote(_ request: TerminalScrollRequest) {
        remoteInFlight = request
        remoteTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
                    self.completeRemote(request, response: nil)
                    return
                }
                response = plannedResponse
            }
            self.completeRemote(request, response: response)
        }
    }

    private func completeRemote(_ request: TerminalScrollRequest, response: TerminalScrollResponse?) {
        guard remoteInFlight?.interactionEpoch == request.interactionEpoch,
              remoteInFlight?.clientRevision == request.clientRevision else {
            return
        }
        remoteInFlight = nil
        remoteTask = nil
        guard request.interactionEpoch == interactionEpoch else { return }

        guard let response,
              response.accepted,
              response.interactionEpoch == interactionEpoch,
              response.clientRevision == request.clientRevision else {
            recoverFromLaneFailure()
            return
        }

        if response.clientRevision == latestClientRevision {
            pendingResponse = response
        } else if response.renderGrid != nil,
                  var pending = remotePending,
                  pending.prefetchWindow == nil {
            pending.prefetchWindow = request.prefetchWindow
            remotePending = pending
        }

        if let next = remotePending {
            remotePending = nil
            startRemote(next)
        }
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

    private func invalidate(nextEpoch: UInt64, snapToBottom: Bool) {
        localTask?.cancel()
        localTask = nil
        remoteTask?.cancel()
        remoteTask = nil
        localInFlight = nil
        localPending = nil
        remoteInFlight = nil
        remotePending = nil
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

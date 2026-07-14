import CMUXMobileCore
import Foundation

typealias TerminalInteractionReceipt = TerminalSurfaceMutationReceipt

/// One mounted surface's ordered interaction owner. Every scroll, click, and
/// input enters `intents`; `phase` is the only active transaction state.
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
    typealias SendInput = @MainActor @Sendable (
        _ surfaceID: String,
        _ interactionEpoch: UInt64,
        _ input: TerminalInputIntent
    ) async -> Bool
    typealias InputBufferDidReject = @MainActor @Sendable (_ pendingByteCount: Int) -> Void
    typealias SupportsOrderedRemoteRuns = @MainActor @Sendable () -> Bool
    typealias InteractionDeadline = @MainActor @Sendable (_ budget: Duration) async -> Void
    typealias PrepareIntent = @MainActor @Sendable () -> Void
    typealias DeliverAuthoritative = @MainActor @Sendable (
        _ frame: MobileTerminalRenderGridFrame,
        _ interactionEpoch: UInt64,
        _ clientRevision: UInt64,
        _ followingScrollRuns: [MobileTerminalScrollRun]
    ) -> Bool
    typealias CompleteGridlessAuthoritative = @MainActor @Sendable (_ renderRevision: UInt64?) -> Bool
    typealias ReconciliationDidComplete = @MainActor @Sendable () -> Void
    typealias RequestReplay = @MainActor @Sendable (_ interactionEpoch: UInt64) -> Void
    typealias AdvanceEpoch = @MainActor @Sendable () -> UInt64
    typealias AdvanceInputEpoch = @MainActor @Sendable (_ submissionCount: Int) -> UInt64

    struct ScrollIntent {
        var runs: [MobileTerminalScrollRun]
        var submissionCount: Int
        var localReceipts: [TerminalSurfaceMutationReceipt]

        mutating func append(_ run: MobileTerminalScrollRun) -> Bool {
            if let lastIndex = runs.indices.last,
               TerminalScrollRequest.canCoalesce(runs[lastIndex], run) {
                runs[lastIndex].merge(run)
                submissionCount += 1
                return true
            }
            guard runs.count < maximumQueuedInteractionCount else { return false }
            runs.append(run)
            submissionCount += 1
            return true
        }
    }

    struct ScrollTransaction {
        let id: UUID
        let request: TerminalScrollRequest
        let requiresLocalApply: Bool
        var localApplied: Bool
        var remoteCompleted = false
        var response: TerminalScrollResponse?
        var awaitingAuthoritative = false
    }

    struct ClickTransaction {
        let id: UUID
        let col: Int
        let row: Int
        var epoch: UInt64?
    }

    enum Intent {
        case scroll(ScrollIntent)
        case settlement
        case click(col: Int, row: Int)
        case input(InputTransaction)

        var cost: Int {
            switch self {
            case .scroll, .settlement, .click, .input: 1
            }
        }

        var isOptimisticallyAppliedScroll: Bool {
            guard case .scroll(let scroll) = self else { return false }
            return !scroll.localReceipts.isEmpty
        }
    }

    enum Phase {
        case idle
        case scroll(ScrollTransaction)
        case clickBarrier(ClickTransaction)
        case clickSend(ClickTransaction)
        case inputSnap(InputTransaction)
        case inputSend(InputTransaction)

        var defersLiveRenderGrid: Bool {
            if case .scroll = self { return true }
            return false
        }
    }

    nonisolated static let maximumQueuedInteractionCount = 64
    nonisolated static let maximumQueuedInputByteCount = 64 * 1_024
    nonisolated static let interactionDeadlineMilliseconds: UInt64 = 200
    nonisolated static let maximumInteractionPlanDeadlineIntervals: UInt64 = 3
    nonisolated static let interactionDeadlineDuration = Duration.milliseconds(
        Int64(interactionDeadlineMilliseconds)
    )
    nonisolated static let interactionRPCDeadlineNanoseconds =
        interactionDeadlineMilliseconds * 1_000_000

    nonisolated static func interactionPlanDeadlineDuration(
        plannedRequestCount: Int
    ) -> Duration {
        let intervals = min(
            UInt64(max(plannedRequestCount, 1)),
            maximumInteractionPlanDeadlineIntervals
        )
        return .milliseconds(Int64(interactionDeadlineMilliseconds * intervals))
    }

    let token: UUID
    let surfaceID: String
    let enqueueLocal: EnqueueLocal
    let enqueueBarrier: EnqueueBarrier
    let enqueueScrollToBottom: EnqueueScrollToBottom
    let cancelLocal: CancelLocal
    let sendRemote: SendRemote
    let sendClick: SendClick
    let sendInput: SendInput
    let inputBufferDidReject: InputBufferDidReject
    let supportsOrderedRemoteRuns: SupportsOrderedRemoteRuns
    let interactionDeadline: InteractionDeadline
    let prepareIntent: PrepareIntent
    let prepareInput: PrepareIntent
    let deliverAuthoritative: DeliverAuthoritative
    let completeGridlessAuthoritative: CompleteGridlessAuthoritative
    let reconciliationDidComplete: ReconciliationDidComplete
    let requestReplay: RequestReplay
    let advanceEpoch: AdvanceEpoch
    let advanceInputEpoch: AdvanceInputEpoch

    var interactionEpoch: UInt64
    var latestClientRevision: UInt64 = 0
    var latestReconciledRevision: UInt64 = 0
    var latestLocallyAppliedRevision: UInt64 = 0
    var phase: Phase = .idle
    var intents = BoundedFIFO<Intent>(capacity: maximumQueuedInteractionCount)
    var queuedInteractionCount = 0
    var queuedInputByteCount = 0
    var localTask: Task<Void, Never>?
    var remoteTask: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?
    var barrierTask: Task<Void, Never>?
    var inputTask: Task<Void, Never>?
    var accumulatedRowsSincePrefetch = 0.0
    var hasPrimedPrefetch = false
    var lastDirectionLines = 1.0
    var lastCol = 0
    var lastRow = 0
    var hasUnsettledScroll = false
    var bottomSnapGeneration: UInt64 = 1
    var consumedBottomSnapGeneration: UInt64 = 0
    var admittedBottomSnapGeneration: UInt64 = 0

    var replayPrefetchWindow: TerminalScrollPrefetchWindow {
        .directional(for: lastDirectionLines)
    }

    var shouldDeferLiveRenderGrid: Bool { phase.defersLiveRenderGrid }

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
        sendInput: @escaping SendInput = { _, _, _ in false },
        inputBufferDidReject: @escaping InputBufferDidReject = { _ in },
        supportsOrderedRemoteRuns: @escaping SupportsOrderedRemoteRuns = { false },
        interactionDeadline: @escaping InteractionDeadline = { budget in
            try? await ContinuousClock().sleep(for: budget)
        },
        prepareIntent: @escaping PrepareIntent,
        prepareInput: @escaping PrepareIntent = {},
        deliverAuthoritative: @escaping DeliverAuthoritative,
        completeGridlessAuthoritative: @escaping CompleteGridlessAuthoritative,
        reconciliationDidComplete: @escaping ReconciliationDidComplete,
        requestReplay: @escaping RequestReplay,
        advanceEpoch: @escaping AdvanceEpoch,
        advanceInputEpoch: AdvanceInputEpoch? = nil
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
        self.sendInput = sendInput
        self.inputBufferDidReject = inputBufferDidReject
        self.supportsOrderedRemoteRuns = supportsOrderedRemoteRuns
        self.interactionDeadline = interactionDeadline
        self.prepareIntent = prepareIntent
        self.prepareInput = prepareInput
        self.deliverAuthoritative = deliverAuthoritative
        self.completeGridlessAuthoritative = completeGridlessAuthoritative
        self.reconciliationDidComplete = reconciliationDidComplete
        self.requestReplay = requestReplay
        self.advanceEpoch = advanceEpoch
        self.advanceInputEpoch = advanceInputEpoch ?? { submissionCount in
            var epoch: UInt64 = 0
            for _ in 0..<submissionCount {
                epoch = advanceEpoch()
            }
            return epoch
        }
    }

    func submit(lines: Double, col: Int, row: Int) {
        submit(MobileTerminalScrollRun(lines: lines, col: col, row: row))
    }

    func submit(_ run: MobileTerminalScrollRun) {
        guard run.hasEffect else { return }
        markBottomSnapNeeded()
        hasUnsettledScroll = true
        let mayApplyOptimistically: Bool
        if case .scroll = phase {
            mayApplyOptimistically = intents.count == 0
                || intents.last?.isOptimisticallyAppliedScroll == true
        } else {
            mayApplyOptimistically = false
        }
        let localReceipt = mayApplyOptimistically ? enqueueLocal([run]) : nil
        var matchedScroll = false
        let merged = intents.mutateLast { intent in
            guard case .scroll(var scroll) = intent else { return false }
            matchedScroll = true
            guard scroll.append(run) else { return false }
            if let localReceipt,
               !scroll.localReceipts.contains(where: { $0 === localReceipt }) {
                scroll.localReceipts.append(localReceipt)
            }
            intent = .scroll(scroll)
            return true
        }
        if matchedScroll {
            guard merged else {
                recoverFromLaneFailure()
                return
            }
        } else {
            guard reserveQueuedInteraction() else { return }
            guard intents.append(.scroll(ScrollIntent(
                runs: [run],
                submissionCount: 1,
                localReceipts: localReceipt.map { [$0] } ?? []
            ))) else {
                queuedInteractionCount -= 1
                recoverFromLaneFailure()
                return
            }
        }
        startNextIntentIfIdle()
    }

    func submitClick(col: Int, row: Int) {
        enqueue(.click(col: max(0, col), row: max(0, row)))
    }

    func interactionDidBegin() {}

    func interactionDidEnd() {
        guard hasUnsettledScroll else { return }
        hasUnsettledScroll = false
        enqueue(.settlement)
    }

    func invalidateForRecovery() -> UInt64 {
        markBottomSnapNeeded()
        let nextEpoch = advanceEpoch()
        invalidate(
            nextEpoch: nextEpoch,
            cancelLocalInteraction: false,
            preserveDispatchedInput: true
        )
        return interactionEpoch
    }

    func invalidateForConnectionReset(preservingDispatchedInput: Bool) -> UInt64 {
        markBottomSnapNeeded()
        let nextEpoch = advanceEpoch()
        invalidate(
            nextEpoch: nextEpoch,
            cancelLocalInteraction: false,
            preserveDispatchedInput: preservingDispatchedInput
        )
        return interactionEpoch
    }

    func cancelForUnmount(nextEpoch: UInt64) {
        invalidate(
            nextEpoch: nextEpoch,
            cancelLocalInteraction: false,
            preserveDispatchedInput: true
        )
    }

    func recoverFromLaneFailure() {
        markBottomSnapNeeded()
        let nextEpoch = advanceEpoch()
        invalidate(
            nextEpoch: nextEpoch,
            cancelLocalInteraction: false,
            preserveDispatchedInput: true
        )
        requestReplay(nextEpoch)
    }

    private func reserveQueuedInteraction() -> Bool {
        guard queuedInteractionCount < Self.maximumQueuedInteractionCount else {
            if queuedInputByteCount > 0 {
                inputBufferDidReject(queuedInputByteCount)
            } else {
                recoverFromLaneFailure()
            }
            return false
        }
        queuedInteractionCount += 1
        return true
    }

    @discardableResult
    private func enqueue(_ intent: Intent) -> Bool {
        guard reserveQueuedInteraction() else { return false }
        guard intents.append(intent) else {
            queuedInteractionCount -= 1
            recoverFromLaneFailure()
            return false
        }
        startNextIntentIfIdle()
        return true
    }

    func removeNextIntent() -> Intent? {
        guard let next = intents.removeFirst() else { return nil }
        queuedInteractionCount = max(0, queuedInteractionCount - next.cost)
        if case .input(let input) = next {
            queuedInputByteCount = max(0, queuedInputByteCount - input.bufferedByteCount)
        }
        return next
    }

    func markBottomSnapNeeded() {
        guard consumedBottomSnapGeneration == bottomSnapGeneration
                || admittedBottomSnapGeneration == bottomSnapGeneration else { return }
        bottomSnapGeneration &+= 1
        if bottomSnapGeneration == 0 { bottomSnapGeneration = 1 }
    }

    func recordBottomSnapAdmission(_ generation: UInt64) {
        guard generation != consumedBottomSnapGeneration else { return }
        admittedBottomSnapGeneration = generation
    }

    func prefetchWindow(for run: MobileTerminalScrollRun) -> TerminalScrollPrefetchWindow? {
        accumulatedRowsSincePrefetch += run.prefetchDistanceRows
        guard !hasPrimedPrefetch
                || accumulatedRowsSincePrefetch >= TerminalScrollPrefetchWindow.refreshDistanceRows else {
            return nil
        }
        hasPrimedPrefetch = true
        accumulatedRowsSincePrefetch = 0
        return .directional(for: run.directionValue)
    }

    func prefetchWindow(for lines: Double) -> TerminalScrollPrefetchWindow? {
        prefetchWindow(for: MobileTerminalScrollRun(lines: lines, col: 0, row: 0))
    }

    func advanceToNextEpoch() -> UInt64 {
        interactionEpoch = advanceEpoch()
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
        return interactionEpoch
    }

    private func invalidate(
        nextEpoch: UInt64,
        cancelLocalInteraction: Bool,
        preserveDispatchedInput: Bool = false
    ) {
        let wasDeferring = shouldDeferLiveRenderGrid
        let keepsInputSend: Bool
        if preserveDispatchedInput, case .inputSend = phase {
            // The old client may still acknowledge a non-idempotent send.
            keepsInputSend = true
        } else {
            keepsInputSend = false
        }
        cancelPhaseTasks(preservingInputTask: keepsInputSend)
        if !keepsInputSend {
            resolveActiveInput(false)
        }
        while let intent = intents.removeFirst() {
            if case .input(let input) = intent { input.receipt.resolve(false) }
        }
        queuedInteractionCount = 0
        queuedInputByteCount = 0
        if !keepsInputSend {
            phase = .idle
        }
        interactionEpoch = nextEpoch
        latestClientRevision = 0
        latestLocallyAppliedRevision = 0
        latestReconciledRevision = 0
        accumulatedRowsSincePrefetch = 0
        hasPrimedPrefetch = false
        hasUnsettledScroll = false
        if wasDeferring { reconciliationDidComplete() }
        if cancelLocalInteraction { cancelLocal() }
    }

    func cancelPhaseTasks(preservingInputTask: Bool = false) {
        localTask?.cancel()
        remoteTask?.cancel()
        deadlineTask?.cancel()
        barrierTask?.cancel()
        if !preservingInputTask {
            inputTask?.cancel()
        }
        localTask = nil
        remoteTask = nil
        deadlineTask = nil
        barrierTask = nil
        if !preservingInputTask {
            inputTask = nil
        }
    }

    private func resolveActiveInput(_ result: Bool) {
        switch phase {
        case .inputSnap(let input), .inputSend(let input): input.receipt.resolve(result)
        default: break
        }
    }
}

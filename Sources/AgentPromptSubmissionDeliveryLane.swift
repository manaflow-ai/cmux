import CmuxTerminalCore
import Foundation
internal import os

/// Cross-entrypoint admission gate shared by async sockets and the legacy
/// synchronous dispatcher.
///
/// SAFETY: the lock protects only the bounded reservation counters; terminal
/// state and delivery remain isolated to the lane actor/MainActor.
private final class AgentPromptSubmissionDeliveryGate: @unchecked Sendable {
    private struct State {
        var asyncReservations = 0
        var synchronousActive = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func reserveAsync(maximum: Int) -> Bool {
        state.withLock { state in
            guard !state.synchronousActive,
                  state.asyncReservations < maximum else {
                return false
            }
            state.asyncReservations += 1
            return true
        }
    }

    func cancelAsyncReservation() {
        state.withLock { state in
            state.asyncReservations = max(0, state.asyncReservations - 1)
        }
    }

    func completeAsyncReservation() {
        cancelAsyncReservation()
    }

    func tryBeginSynchronousTurn() -> Bool {
        state.withLock { state in
            guard !state.synchronousActive,
                  state.asyncReservations == 0 else {
                return false
            }
            state.synchronousActive = true
            return true
        }
    }

    func completeSynchronousTurn() {
        state.withLock { state in
            state.synchronousActive = false
        }
    }
}

/// Serializes complete agent prompt transactions through actual delivery.
///
/// The lane owns one admission turn at a time. A turn remains occupied while
/// a cold-surface or clipboard-deferred prompt waits on its delivery receipt,
/// so a later socket request cannot overtake bytes that were admitted first.
actor AgentPromptSubmissionDeliveryLane {
    enum Outcome: Sendable, Equatable {
        case admitted(AgentPromptSubmissionResult)
        case invalidWorkspace
        case invalidSurface
        case laneBusy
    }

    private var isOccupied = false
    private struct WaitingTurn {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waitingTurns: [WaitingTurn] = []
    private let deliveryTimeout: Duration
    private let maximumWaitingTurns: Int
    private let clock: any Clock<Duration>
    private nonisolated let crossEntrypointGate =
        AgentPromptSubmissionDeliveryGate()

    /// Creates a delivery lane with bounded waiting and a cancellable
    /// deadline for a cold or clipboard-deferred transaction.
    init(
        deliveryTimeout: Duration = .seconds(60),
        maximumWaitingTurns: Int = 64,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.deliveryTimeout = deliveryTimeout
        self.maximumWaitingTurns = max(0, maximumWaitingTurns)
        self.clock = clock
    }

    /// Claims the shared turn for a legacy synchronous caller.
    nonisolated func tryBeginSynchronousTurn() -> Bool {
        crossEntrypointGate.tryBeginSynchronousTurn()
    }

    /// Releases a legacy synchronous turn after its receipt resolves.
    nonisolated func completeSynchronousTurn() {
        crossEntrypointGate.completeSynchronousTurn()
    }

    /// Keeps a synchronous turn held until its queued delivery finishes.
    nonisolated func holdSynchronousTurn(
        _ receipt: PromptSubmissionDeliveryReceipt
    ) {
        Task { [self] in
            let result = await self.waitForDelivery(receipt)
            if result == .surfaceUnavailable {
                receipt.cancel()
            }
            self.completeSynchronousTurn()
        }
    }

    /// Runs one MainActor admission and waits for its eventual terminal result.
    ///
    /// - Parameter admission: The MainActor operation that resolves and admits
    ///   the target. The supplied receipt must be completed by the terminal
    ///   surface after the compound write is sent or rejected.
    /// - Returns: The definitive socket-level outcome after delivery.
    func perform(
        _ admission: @escaping @MainActor @Sendable (
            PromptSubmissionDeliveryReceipt
        ) -> Outcome
    ) async -> Outcome {
        guard crossEntrypointGate.reserveAsync(
            maximum: maximumWaitingTurns
        ) else {
            return .laneBusy
        }
        var reservedAsyncTurn = true
        defer {
            if reservedAsyncTurn {
                crossEntrypointGate.completeAsyncReservation()
            }
        }
        guard await acquireTurn() else {
            return .laneBusy
        }
        reservedAsyncTurn = false
        defer { releaseTurn() }
        defer { crossEntrypointGate.completeAsyncReservation() }

        guard !Task.isCancelled else {
            return .laneBusy
        }

        let receipt = PromptSubmissionDeliveryReceipt()
        let admitted = await withTaskCancellationHandler(operation: {
            await MainActor.run {
                guard !Task.isCancelled else {
                    return .laneBusy
                }
                return admission(receipt)
            }
        }, onCancel: {
            // Cancellation before admission must not leave a queued receipt
            // that can later write after the caller has gone away.
            _ = receipt.cancel()
        })
        guard case .admitted(let admittedResult) = admitted else {
            return admitted
        }
        guard case .submitted = admittedResult else {
            return admitted
        }
        let deliveryResult = await waitForDelivery(receipt)
        if deliveryResult == .surfaceUnavailable {
            receipt.cancel()
        }
        return .admitted(Self.resolve(admittedResult, after: deliveryResult))
    }

    private func acquireTurn() async -> Bool {
        guard isOccupied else {
            isOccupied = true
            return true
        }
        guard waitingTurns.count < maximumWaitingTurns else {
            return false
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waitingTurns.append(
                    WaitingTurn(id: id, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelWaitingTurn(id: id) }
        }
    }

    private func releaseTurn() {
        guard !waitingTurns.isEmpty else {
            isOccupied = false
            return
        }
        waitingTurns.removeFirst().continuation.resume(returning: true)
    }

    private func cancelWaitingTurn(id: UUID) {
        guard let index = waitingTurns.firstIndex(where: { $0.id == id }) else {
            return
        }
        waitingTurns.remove(at: index).continuation.resume(returning: false)
    }

    /// Waits for one compound delivery using the lane's bounded deadline.
    ///
    /// This helper does not claim the lane turn; callers that already own a
    /// separate ordering domain can use the same receipt timeout without
    /// allowing an unavailable surface to hold that domain forever.
    ///
    /// - Parameter timeout: An optional shorter deadline for callers with a
    ///   transport-level response budget.
    func waitForDelivery(
        _ receipt: PromptSubmissionDeliveryReceipt,
        timeout: Duration? = nil
    ) async -> PromptSubmissionSendResult {
        let clock = self.clock
        let timeout = timeout ?? deliveryTimeout
        await withTaskGroup(of: PromptSubmissionSendResult.self) { group in
            group.addTask {
                await receipt.wait()
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return .surfaceUnavailable
                }
                return .surfaceUnavailable
            }
            let result = await group.next() ?? .surfaceUnavailable
            if result == .surfaceUnavailable {
                // Claim cancellation before stopping the receipt waiter. If a
                // delivery already claimed its write, wait for its definitive
                // result instead of reporting a timeout after bytes were sent.
                let definitiveResult = await receipt.cancelAndWait()
                group.cancelAll()
                return definitiveResult
            }
            group.cancelAll()
            return result
        }
    }

    private static func resolve(
        _ admitted: AgentPromptSubmissionResult,
        after delivery: PromptSubmissionSendResult
    ) -> AgentPromptSubmissionResult {
        guard case .submitted(
            let workspaceID,
            let surfaceID,
            let wasQueued
        ) = admitted else {
            return admitted
        }
        switch delivery {
        case .sent:
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: wasQueued
            )
        case .queued:
            return .submitted(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                queued: true
            )
        case .composerBusy:
            return .rejectedComposerBusy(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .agentScopeUnavailable:
            return .agentScopeUnavailable(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .unknownKey:
            return .invalidSubmitKey(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .inputQueueFull:
            return .inputQueueFull(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .surfaceUnavailable:
            return .surfaceUnavailable(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        case .processExited:
            return .processExited(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            )
        }
    }
}
